"""Selectable Whisper model profiles.

From whisper-dictation-mac (MIT). The menu-title helper it had is gone —
Cyclop has no menu bar of its own to build titles for.
"""

from __future__ import annotations

from dataclasses import dataclass


DEFAULT_MODEL_ID = "large-v3-turbo"


@dataclass(frozen=True)
class ModelOption:
    id: str
    label: str
    repo: str
    detail: str
    # Measured from the Hub, so the list can show a size before anything is
    # downloaded and without asking the network for permission to draw itself.
    # A few megabytes off after an upstream reupload costs nothing; the exact
    # figure comes from the dry run when the download actually starts.
    size_mb: int


_MODELS: tuple[ModelOption, ...] = (
    ModelOption(
        id="large-v3-turbo",
        label="Large v3 Turbo",
        repo="mlx-community/whisper-large-v3-turbo",
        detail="best speed/quality default",
        size_mb=1539,
    ),
    ModelOption(
        id="large-v3",
        label="Large v3",
        repo="mlx-community/whisper-large-v3-mlx",
        detail="smarter, slower, better technical words",
        size_mb=2941,
    ),
    ModelOption(
        id="large-v3-turbo-q4",
        label="Large v3 Turbo Q4",
        repo="mlx-community/whisper-large-v3-turbo-q4",
        detail="smaller download, near-best quality",
        size_mb=442,
    ),
    ModelOption(
        id="small",
        label="Small",
        repo="mlx-community/whisper-small-mlx",
        detail="low memory, lower quality",
        size_mb=459,
    ),
)


def list_models() -> tuple[ModelOption, ...]:
    return _MODELS


def get_default_model() -> ModelOption:
    return get_model(DEFAULT_MODEL_ID)


def get_model(model_id: str | None) -> ModelOption:
    for model in _MODELS:
        if model.id == model_id:
            return model
    for model in _MODELS:
        if model.id == DEFAULT_MODEL_ID:
            return model
    raise RuntimeError("default model is missing from catalog")


def get_model_for_repo(repo: str | None) -> ModelOption:
    for model in _MODELS:
        if model.repo == repo:
            return model
    return get_default_model()
