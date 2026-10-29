"""Backend configuration, loaded from environment variables and backend/.env."""

from __future__ import annotations

import os
import secrets
from functools import lru_cache
from pathlib import Path
from typing import Literal

from pydantic import AliasChoices, Field, SecretStr, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

DEFAULT_DATA_DIR = Path.home() / "Library" / "Application Support" / "Orbito"
TOKEN_FILE_NAME = "api-token"


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="ORBITO_", env_file=".env", extra="ignore"
    )

    host: str = "127.0.0.1"
    port: int = Field(default=8765, ge=1024, le=65535)
    api_token: str | None = None
    data_dir: Path = DEFAULT_DATA_DIR

    llm_provider: Literal["auto", "bedrock", "groq", "mock"] = "auto"

    # Groq (OpenAI-compatible API). The key is never logged or returned.
    groq_api_key: SecretStr | None = Field(
        default=None, validation_alias=AliasChoices("ORBITO_GROQ_API_KEY", "GROQ_API_KEY")
    )
    groq_model_id: str | None = None
    groq_timeout_seconds: float = Field(default=30, gt=0, le=120)

    bedrock_model_id: str | None = None
    bedrock_timeout_seconds: float = Field(default=30, gt=0, le=120)
    # Standard AWS names, read from the environment or backend/.env.
    aws_region: str | None = Field(
        default=None,
        validation_alias=AliasChoices("ORBITO_AWS_REGION", "AWS_REGION", "AWS_DEFAULT_REGION"),
    )
    # Bedrock API key (an alternative to IAM credentials). Never logged or returned.
    bedrock_api_key: SecretStr | None = Field(
        default=None, validation_alias=AliasChoices("AWS_BEARER_TOKEN_BEDROCK")
    )

    speech_provider: Literal["auto", "whistle", "mock"] = "auto"

    # Wake word (openWakeWord): a built-in model name or a path to a custom .onnx file.
    wake_word_model: str = "hey_jarvis"
    # The phrase as Whistle should hear it; used to double-check each detection.
    wake_word_phrase: str = "hey jarvis"
    wake_word_threshold: float = Field(default=0.5, gt=0, lt=1)

    log_level: str = "INFO"

    @field_validator("host")
    @classmethod
    def _loopback_only(cls, value: str) -> str:
        if value not in {"127.0.0.1", "localhost"}:
            raise ValueError("The backend may only bind to 127.0.0.1")
        return "127.0.0.1"

    @field_validator(
        "bedrock_model_id", "api_token", "aws_region", "bedrock_api_key",
        "groq_api_key", "groq_model_id", mode="before",
    )
    @classmethod
    def _blank_is_none(cls, value: str | None) -> str | None:
        return value.strip() or None if isinstance(value, str) else value


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
