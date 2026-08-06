"""Lightweight text cleanup applied to Whisper output before insertion.

From whisper-dictation-mac (MIT), carried over unchanged.

The goal is conservative: we don't rewrite content (no LLM here), we just
fix the cosmetic issues Whisper sometimes leaves behind so the inserted
text looks natural in any field.
"""

from __future__ import annotations

import re

from .config import CleanerConfig

_MULTI_SPACE = re.compile(r"[ \t]{2,}")
_SPACE_BEFORE_PUNCT = re.compile(r"\s+([,.;:!?…])")
_NO_SPACE_AFTER_PUNCT = re.compile(r"([,.;:!?…])(?=[^\s\d.,;:!?…)\]'\"»])")
_LEADING_SPACES_PER_LINE = re.compile(r"^[ \t]+", re.MULTILINE)
_TRAILING_SPACES_PER_LINE = re.compile(r"[ \t]+$", re.MULTILINE)
_TRIPLE_NEWLINE = re.compile(r"\n{3,}")


def clean_text(raw: str, config: CleanerConfig | None = None) -> str:
    """Normalise spaces, punctuation and capitalisation.

    Returns an empty string when the input is empty/whitespace so callers
    can short-circuit clipboard and paste operations.
    """
    if not raw:
        return ""

    cfg = config or CleanerConfig()

    text = raw.replace("\r\n", "\n").replace("\r", "\n").strip()
    if not text:
        return ""

    text = _LEADING_SPACES_PER_LINE.sub("", text)
    text = _TRAILING_SPACES_PER_LINE.sub("", text)
    text = _TRIPLE_NEWLINE.sub("\n\n", text)
    text = _MULTI_SPACE.sub(" ", text)
    text = _SPACE_BEFORE_PUNCT.sub(r"\1", text)
    text = _NO_SPACE_AFTER_PUNCT.sub(r"\1 ", text)
    text = _MULTI_SPACE.sub(" ", text)

    if cfg.capitalize_first and text and text[0].isalpha() and text[0].islower():
        text = text[0].upper() + text[1:]

    if cfg.trailing_space and not text.endswith((" ", "\n")):
        text = text + " "

    return text
