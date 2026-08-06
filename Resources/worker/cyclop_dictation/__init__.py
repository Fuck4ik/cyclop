"""Transcription settings and helpers the worker runs on.

Adapted from whisper-dictation-mac by Sergej (MIT), the standalone app Cyclop's
dictation grew out of: `config`, `transcriber`, `text_cleaner`,
`model_catalog` and `preferences` are its modules with everything Cyclop does
in Swift — recording, hotkey, insertion, indicator — left behind. The
decoding settings inside `config` are carried over verbatim; they were tuned
against real recordings and are not ours to drift.

Kept as a package next to the worker rather than imported from the other
app's virtualenv, which is what used to happen and is why dictation could not
start on a machine that never had WhisperDictation installed.
"""

__all__ = ["config", "model_catalog", "preferences", "text_cleaner", "transcriber"]
