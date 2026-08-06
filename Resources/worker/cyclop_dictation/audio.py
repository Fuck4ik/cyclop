"""Reading Cyclop's own recordings without ffmpeg.

mlx-whisper loads audio by shelling out to the ffmpeg CLI, which macOS does
not ship — a bundled runtime that relied on it would still fail on a machine
that never installed ffmpeg by hand. Cyclop writes plain 16 kHz mono PCM
(see AudioRecorder), so the worker decodes it here and hands the samples to
the model directly. Anything this module does not understand it declines by
returning None, and mlx-whisper's own path takes over.
"""

from __future__ import annotations

import sys
import wave
from array import array
from math import gcd
from pathlib import Path

SAMPLE_RATE = 16_000


def decode_pcm(raw: bytes, sample_width: int, channels: int) -> array | None:
    """Turn interleaved PCM frames into mono float samples in [-1, 1].

    Returns None for anything but 8/16/32-bit integer PCM — 24-bit and float
    WAVs exist, we just have no reason to write our own reader for them.
    """
    if channels < 1 or not raw:
        return None

    if sample_width == 1:
        # 8-bit WAV is unsigned, centred on 128.
        samples = array("f", ((value - 128) / 128.0 for value in raw))
    elif sample_width in (2, 4):
        code, scale = ("h", 32768.0) if sample_width == 2 else ("i", 2147483648.0)
        pcm = array(code)
        pcm.frombytes(raw[: len(raw) - len(raw) % sample_width])
        if sys.byteorder == "big":
            # WAV is little-endian; array() reads in native order.
            pcm.byteswap()
        samples = array("f", (value / scale for value in pcm))
    else:
        return None

    if channels > 1:
        frames = len(samples) // channels
        samples = array(
            "f",
            (
                sum(samples[frame * channels : (frame + 1) * channels]) / channels
                for frame in range(frames)
            ),
        )
    return samples


def load_wav(path: Path):
    """16 kHz mono float32 for the model, or None to let mlx-whisper try."""
    try:
        with wave.open(str(path), "rb") as source:
            params = source.getparams()
            raw = source.readframes(params.nframes)
    except (wave.Error, EOFError, OSError):
        return None

    samples = decode_pcm(raw, params.sampwidth, params.nchannels)
    if samples is None:
        return None

    import numpy as np

    audio = np.array(samples, dtype=np.float32)
    if params.framerate != SAMPLE_RATE:
        return _resample(audio, params.framerate)
    return audio


def _resample(audio, rate: int):
    """Only ever needed for recordings Cyclop did not make itself."""
    try:
        from scipy.signal import resample_poly
    except ImportError:
        return None
    step = gcd(int(rate), SAMPLE_RATE)
    return resample_poly(audio, SAMPLE_RATE // step, int(rate) // step).astype("float32")
