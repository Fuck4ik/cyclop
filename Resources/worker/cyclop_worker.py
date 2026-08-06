"""Transcription worker for Cyclop.

Reads one JSON request per line on stdin, answers with one JSON response per
line on stdout. Exits when stdin closes, so it cannot outlive the app.

The whole point of this process is the tuned mlx-whisper setup: the model, the
initial prompt and the decoding parameters come from `whisper_dictation.config`
untouched. Everything else — hotkey, recording, insertion — lives in Swift.
"""

from __future__ import annotations

import json
import sys
import threading
import time

IDLE_SECONDS = 600


def _log(message: str) -> None:
    # stderr, so it never lands in the response stream.
    print(f"cyclop-worker: {message}", file=sys.stderr, flush=True)


class Engine:
    """Owns the model and decides when to let go of it."""

    def __init__(self, transcriber=None, idle_seconds: float = IDLE_SECONDS, clock=time.monotonic):
        self._transcriber = transcriber
        self._config = None
        self._cleaner_config = None
        self._idle_seconds = idle_seconds
        self._clock = clock
        self._last_used = None
        self._loaded = transcriber is not None
        # Mutex protecting transcriber state: transcribe(), unload(), and
        # maybe_unload_idle() are mutually exclusive to prevent the idle-watch
        # thread from unloading the model while transcribe() is running.
        self._state_lock = threading.RLock()

    def _ensure(self):
        if self._transcriber is None:
            from whisper_dictation.config import AppConfig, load_config
            from whisper_dictation.transcriber import WhisperTranscriber

            # load_config() calls AppConfig.ensure_dirs(), which creates
            # WhisperDictation's own ~/Library/.../WhisperDictation/recordings
            # folder as a side effect of just reading the model preference —
            # Cyclop keeps its own recordings elsewhere (see AudioRecorder)
            # and has no use for that folder, so it should not bring it back
            # into existence after the standalone app is uninstalled. Patched
            # out here, in this process only, rather than in
            # whisper_dictation itself: that package belongs to the other
            # app, not to Cyclop, to edit.
            AppConfig.ensure_dirs = lambda self: None
            config = load_config()
            self._config = config
            self._cleaner_config = config.cleaner
            self._transcriber = WhisperTranscriber(config.whisper)
            _log(f"model {config.whisper.model}")
        return self._transcriber

    def transcribe(self, path: str) -> dict:
        from pathlib import Path

        with self._state_lock:
            started = time.monotonic()
            # Mark as in-use at the start of transcription to prevent idle-unload
            # from running while we're using the model.
            self._last_used = self._clock()
            transcriber = self._ensure()
            # transcriber expects a Path object, not a string
            audio_path = Path(path)
            raw = transcriber.transcribe(audio_path)
            text = raw.strip()
            if self._cleaner_config is not None:
                from whisper_dictation.text_cleaner import clean_text

                # No trailing .strip() here: clean_text() adds a trailing
                # space on purpose when cfg.trailing_space is set, so the next
                # dictation into the same field doesn't run straight into
                # this one. clean_text() still collapses whitespace-only
                # input to "", so an empty result stays reliably empty.
                text = clean_text(raw, self._cleaner_config)
            self._loaded = True
            # Hand the allocator's cache back straight away: it is the larger half
            # of this process's footprint and nothing needs it between dictations.
            freed = self._clear_cache()
            # The actual model this transcription ran on, straight from
            # load_config() — not a string Swift has to keep in sync by
            # hand. Old WhisperDictation has a model switcher in its menu;
            # without this, a history entry written after switching models
            # would go on claiming the previous one. None only when this
            # Engine was built directly around a stub transcriber (see the
            # tests), which never goes through _ensure() and so never sets
            # self._config.
            model = self._config.whisper.model if self._config is not None else None
            return {
                "text": text,
                "took": round(time.monotonic() - started, 3),
                "freed_mb": freed,
                "model": model,
            }

    def _clear_cache(self) -> float:
        try:
            import mlx.core as mx
        except ImportError:
            return 0.0
        before = mx.get_cache_memory() / 2**20
        mx.clear_cache()
        return round(before - mx.get_cache_memory() / 2**20, 1)

    def unload(self) -> dict:
        with self._state_lock:
            freed = 0.0
            try:
                import mlx.core as mx
                from mlx_whisper.transcribe import ModelHolder

                before = (mx.get_active_memory() + mx.get_cache_memory()) / 2**20
                # The weights are held by a class attribute; dropping it is what
                # actually releases them.
                ModelHolder.model = None
                ModelHolder.model_path = None
                mx.clear_cache()
                freed = round(before - (mx.get_active_memory() + mx.get_cache_memory()) / 2**20, 1)
            except ImportError:
                pass
            self._transcriber = None
            self._loaded = False
            self._last_used = None
            _log(f"unloaded, freed {freed} MB")
            return {"unloaded": True, "freed_mb": freed}

    def maybe_unload_idle(self) -> dict | None:
        with self._state_lock:
            if not self._loaded or self._last_used is None:
                return None
            if self._clock() - self._last_used <= self._idle_seconds:
                return None
            # unload() is already protected by the lock, but we already hold it
            # so just call the implementation body.
            freed = 0.0
            try:
                import mlx.core as mx
                from mlx_whisper.transcribe import ModelHolder

                before = (mx.get_active_memory() + mx.get_cache_memory()) / 2**20
                ModelHolder.model = None
                ModelHolder.model_path = None
                mx.clear_cache()
                freed = round(before - (mx.get_active_memory() + mx.get_cache_memory()) / 2**20, 1)
            except ImportError:
                pass
            self._transcriber = None
            self._loaded = False
            self._last_used = None
            _log(f"unloaded, freed {freed} MB")
            return {"unloaded": True, "freed_mb": freed}


def handle_line(line: str, engine: Engine) -> dict:
    try:
        request = json.loads(line)
    except json.JSONDecodeError:
        return {"error": "malformed request"}

    command = request.get("cmd")
    try:
        if command == "transcribe":
            return engine.transcribe(request.get("path", ""))
        if command == "unload":
            return engine.unload()
        if command == "ping":
            return {"ok": True}
        return {"error": f"unknown command: {command}"}
    except Exception as exc:  # never let one bad request kill the worker
        return {"error": f"{type(exc).__name__}: {exc}"}


def _idle_watch(engine: Engine, emit) -> None:
    """Monitor and unload the model after idle timeout.

    Runs in a daemon thread; exceptions are logged to stderr so the worker
    thread stays alive even if idle-unload crashes.
    """
    while True:
        try:
            time.sleep(30)
            report = engine.maybe_unload_idle()
            if report is not None:
                emit(report)
        except Exception as exc:
            _log(f"idle-watch error (non-fatal): {type(exc).__name__}: {exc}")


def main() -> int:
    engine = Engine()
    lock = threading.Lock()

    def emit(payload: dict) -> None:
        with lock:
            sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
            sys.stdout.flush()

    threading.Thread(target=_idle_watch, args=(engine, emit), daemon=True).start()

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        emit(handle_line(line, engine))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
