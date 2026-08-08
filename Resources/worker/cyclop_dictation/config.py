"""What the recogniser runs on: model, prompt, decoding parameters.

From whisper-dictation-mac (MIT). The decoding settings below are carried
over verbatim — they were tuned against real recordings and reproduce the
existing history character for character. The knobs about recording, hotkey
and the floating indicator are gone: Cyclop does all of that in Swift.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field, replace
from pathlib import Path

from .model_catalog import get_model
from .preferences import PreferencesStore


def _default_data_dir() -> Path:
    return Path.home() / "Library" / "Application Support" / "Cyclop"


@dataclass(frozen=True)
class WhisperConfig:
    # MLX-optimised Whisper checkpoints from the Hugging Face MLX community.
    # large-v3-turbo gives the best quality/speed balance on Apple Silicon.
    # Override via CYCLOP_WHISPER_MODEL env var to try smaller/quantised
    # variants:
    #   - mlx-community/whisper-large-v3-turbo-q4 (smaller, near-real-time)
    #   - mlx-community/whisper-small-mlx (low memory)
    # The name is Cyclop's own rather than the WHISPER_MODEL the other app
    # reads: a machine that still has both installed must be able to point
    # them at different models.
    model: str = field(
        default_factory=lambda: os.environ.get(
            "CYCLOP_WHISPER_MODEL", "mlx-community/whisper-large-v3-turbo"
        )
    )
    # None = let Whisper auto-detect. We use auto-detect so RU + EN code-switching
    # is handled naturally. Override via CYCLOP_WHISPER_LANGUAGE if you only
    # dictate one.
    language: str | None = field(
        default_factory=lambda: os.environ.get("CYCLOP_WHISPER_LANGUAGE") or None
    )
    # Initial prompt biases Whisper towards mixed RU/EN dictation and keeps
    # English technical terms in English. Whisper's prompt window is ~224
    # tokens, so we pack as many real-world technical terms as possible to
    # anchor the language model toward correct spelling and code-switching.
    initial_prompt: str = (
        "Это диктовка на русском языке для разработчика. Часто встречаются "
        "английские слова, бренды и технические термины — их всегда пиши "
        "на английском, без транслита. "
        "Vocabulary: GitHub, GitLab, Bitbucket, pull request, merge, commit, "
        "branch, rebase, fork, push, pull, clone, issue, reviewer, approve, "
        "request changes, sprint, backlog, standup, retro, deadline, release, "
        "deploy, deployment, staging, production, rollback, hotfix, feature "
        "flag, A/B test, OAuth, JWT, JSON, YAML, REST, gRPC, GraphQL, API, "
        "SDK, CLI, IDE, DevTools, localStorage, sessionStorage, cookie, "
        "endpoint, microservice, Kubernetes, Docker, Terraform, Prometheus, "
        "Grafana, PagerDuty, Datadog, Sentry, Postgres, MySQL, Redis, "
        "MongoDB, Kafka, RabbitMQ, S3, CDN, frontend, backend, fullstack, "
        "latency, throughput, RPS, SLA, SLO, KPI, OKR, roadmap, MVP, POC, "
        "Python, JavaScript, TypeScript, React, Next.js, Node.js, FastAPI, "
        "Django, Cursor, Figma, Notion, Slack, Telegram, Zoom, Linear, "
        "Jira, Confluence, MacBook, iPhone, Whisper, OpenAI, Anthropic, "
        "Claude, ChatGPT, GPT, LLM, embedding, RAG, vector, pgvector, "
        "Tesla, Илон Маск, Сэм Альтман."
    )
    temperature: float = 0.0
    condition_on_previous_text: bool = False


@dataclass(frozen=True)
class CleanerConfig:
    # Append a trailing space after the inserted text so the next key
    # continues naturally. Disable to insert exactly what Whisper produced.
    trailing_space: bool = True
    # Capitalise the first letter when the surrounding context is unknown.
    capitalize_first: bool = True


@dataclass(frozen=True)
class AppConfig:
    whisper: WhisperConfig = field(default_factory=WhisperConfig)
    cleaner: CleanerConfig = field(default_factory=CleanerConfig)
    data_dir: Path = field(default_factory=_default_data_dir)

    @property
    def preferences_path(self) -> Path:
        return self.data_dir / "dictation-preferences.json"


def load_config(data_dir: Path | None = None) -> AppConfig:
    """Build configuration from defaults + environment variables.

    Creates nothing on disk. The original called ensure_dirs() here, so
    merely asking which model to use laid out a recordings folder — Cyclop
    keeps its recordings elsewhere and its Swift side owns that directory
    anyway. Reading a preference is not a reason to write.
    """
    cfg = AppConfig(data_dir=data_dir or _default_data_dir())
    if "CYCLOP_WHISPER_MODEL" not in os.environ:
        preferences = PreferencesStore(cfg.preferences_path).load()
        selected_model = get_model(preferences.selected_model_id)
        cfg = replace(cfg, whisper=replace(cfg.whisper, model=selected_model.repo))
    return cfg
