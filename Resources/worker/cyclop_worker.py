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

    def _ensure(self):
        if self._transcriber is None:
            from whisper_dictation.config import load_config
            from whisper_dictation.transcriber import WhisperTranscriber

            config = load_config()
            self._config = config
            self._cleaner_config = config.cleaner
            self._transcriber = WhisperTranscriber(config.whisper)
            _log(f"model {config.whisper.model}")
        return self._transcriber

    def transcribe(self, path: str) -> dict:
        from pathlib import Path

        started = time.monotonic()
        transcriber = self._ensure()
        # transcriber expects a Path object, not a string
        audio_path = Path(path)
        raw = transcriber.transcribe(audio_path)
        text = raw.strip()
        if self._cleaner_config is not None:
            from whisper_dictation.text_cleaner import clean_text

            text = clean_text(raw, self._cleaner_config).strip()
        self._loaded = True
        self._last_used = self._clock()
        # Hand the allocator's cache back straight away: it is the larger half
        # of this process's footprint and nothing needs it between dictations.
        freed = self._clear_cache()
        return {"text": text, "took": round(time.monotonic() - started, 3), "freed_mb": freed}

    def _clear_cache(self) -> float:
        try:
            import mlx.core as mx
        except ImportError:
            return 0.0
        before = mx.get_cache_memory() / 2**20
        mx.clear_cache()
        return round(before - mx.get_cache_memory() / 2**20, 1)

    def unload(self) -> dict:
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
        if not self._loaded or self._last_used is None:
            return None
        if self._clock() - self._last_used <= self._idle_seconds:
            return None
        return self.unload()


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
    while True:
        time.sleep(30)
        report = engine.maybe_unload_idle()
        if report is not None:
            emit(report)


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
