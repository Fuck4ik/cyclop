"""Local Whisper transcription via mlx-whisper (Apple Silicon).

From whisper-dictation-mac (MIT), minus the warm-up and model-switching it
needed for its own menu bar.

Loading the model the first time downloads weights from Hugging Face into
``~/.cache/huggingface``. Subsequent runs are fully offline.
"""

from __future__ import annotations

import logging
import time
from pathlib import Path

from .audio import load_wav
from .config import WhisperConfig

log = logging.getLogger(__name__)


class TranscriberError(RuntimeError):
    """Raised when transcription cannot be performed."""


class WhisperTranscriber:
    """Thin wrapper around ``mlx_whisper.transcribe``.

    The model is lazily imported so the rest of the app (config, recorder,
    text cleaner, hotkey loop) can run without ``mlx-whisper`` installed
    during development or on Intel Macs.
    """

    def __init__(self, config: WhisperConfig) -> None:
        self._config = config
        self._mlx_whisper = None

    @property
    def model(self) -> str:
        return self._config.model

    def _ensure_backend(self):
        if self._mlx_whisper is None:
            try:
                import mlx_whisper
            except ImportError as exc:
                raise TranscriberError(
                    "mlx-whisper is not installed. Install with "
                    "`pip install mlx-whisper`. On Intel Macs use whisper.cpp instead."
                ) from exc
            self._mlx_whisper = mlx_whisper
            log.info("mlx-whisper backend ready (model=%s)", self._config.model)
        return self._mlx_whisper

    def transcribe(self, audio_path: Path) -> str:
        backend = self._ensure_backend()

        if not audio_path.exists():
            raise TranscriberError(f"Audio file not found: {audio_path}")

        kwargs: dict = {
            "path_or_hf_repo": self._config.model,
            "temperature": self._config.temperature,
            "condition_on_previous_text": self._config.condition_on_previous_text,
            "initial_prompt": self._config.initial_prompt,
        }
        if self._config.language:
            kwargs["language"] = self._config.language

        # Samples rather than a path wherever we can read the file ourselves:
        # handing over a path sends mlx-whisper to the ffmpeg CLI, which is not
        # part of macOS and so is missing on any machine that never installed
        # it. See cyclop_dictation.audio.
        audio = load_wav(audio_path)
        source = str(audio_path) if audio is None else audio

        started = time.monotonic()
        try:
            result = backend.transcribe(source, **kwargs)
        except Exception as exc:
            raise TranscriberError(f"Whisper failed: {exc}") from exc

        elapsed = time.monotonic() - started
        text = (result.get("text") or "").strip()
        log.info(
            "Transcribed %s in %.2fs -> %d chars",
            audio_path.name,
            elapsed,
            len(text),
        )
        return text
