"""Which model the user picked, remembered between runs.

From whisper-dictation-mac (MIT). Reading never creates anything: a missing
file means the default model, not a reason to start laying out directories in
Application Support — see the note in `config`.
"""

from __future__ import annotations

import json
import logging
from dataclasses import asdict, dataclass
from pathlib import Path

from .model_catalog import DEFAULT_MODEL_ID, get_model

log = logging.getLogger(__name__)


@dataclass(frozen=True)
class UserPreferences:
    selected_model_id: str = DEFAULT_MODEL_ID


class PreferencesStore:
    """Read/write a small JSON preferences file under Application Support."""

    def __init__(self, path: Path) -> None:
        self._path = path

    @property
    def path(self) -> Path:
        return self._path

    def load(self) -> UserPreferences:
        if not self._path.exists():
            return UserPreferences()
        try:
            raw = json.loads(self._path.read_text(encoding="utf-8"))
        except Exception as exc:
            log.warning("Could not read preferences %s: %s", self._path, exc)
            return UserPreferences()

        model_id = raw.get("selected_model_id")
        model = get_model(model_id)
        return UserPreferences(selected_model_id=model.id)

    def save(self, preferences: UserPreferences) -> None:
        model = get_model(preferences.selected_model_id)
        prefs = UserPreferences(selected_model_id=model.id)
        self._path.parent.mkdir(parents=True, exist_ok=True)
        self._path.write_text(
            json.dumps(asdict(prefs), ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
