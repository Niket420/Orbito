"""Backend configuration, loaded from environment variables and backend/.env."""

from __future__ import annotations

import os
import secrets
from functools import lru_cache
from pathlib import Path
from typing import Literal

from pydantic import Field, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

DEFAULT_DATA_DIR = Path.home() / "Library" / "Application Support" / "Whisper"
TOKEN_FILE_NAME = "api-token"


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="WHISPER_", env_file=".env", extra="ignore"
    )

    host: str = "127.0.0.1"
    port: int = Field(default=8765, ge=1024, le=65535)
    api_token: str | None = None
    data_dir: Path = DEFAULT_DATA_DIR

    llm_provider: Literal["auto", "bedrock", "mock"] = "auto"
    bedrock_model_id: str | None = None
    bedrock_timeout_seconds: float = Field(default=30, gt=0, le=120)
    # Region follows the standard AWS variables; WHISPER_AWS_REGION overrides.
    aws_region: str | None = Field(
        default_factory=lambda: os.environ.get("AWS_REGION")
        or os.environ.get("AWS_DEFAULT_REGION")
    )

    speech_provider: Literal["auto", "whistle", "mock"] = "auto"
    log_level: str = "INFO"

    @field_validator("host")
    @classmethod
    def _loopback_only(cls, value: str) -> str:
        if value not in {"127.0.0.1", "localhost"}:
            raise ValueError("The backend may only bind to 127.0.0.1")
        return "127.0.0.1"

    @field_validator("bedrock_model_id", "api_token")
    @classmethod
    def _blank_is_none(cls, value: str | None) -> str | None:
        return value.strip() or None if value else None


def resolve_api_token(settings: Settings) -> str:
    """Return the shared API token, creating a 0600 token file if needed."""
    if settings.api_token:
        return settings.api_token

    settings.data_dir.mkdir(parents=True, exist_ok=True)
    token_path = settings.data_dir / TOKEN_FILE_NAME
    if token_path.exists():
        token = token_path.read_text().strip()
        if token:
            return token

    token = secrets.token_urlsafe(32)
    fd = os.open(token_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as handle:
        handle.write(token)
    return token


@lru_cache
def get_settings() -> Settings:
    return Settings()
