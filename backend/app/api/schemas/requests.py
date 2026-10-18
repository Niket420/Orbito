"""Validated request bodies."""

from __future__ import annotations

from pydantic import BaseModel, ConfigDict, Field, field_validator

from app.agent.instruction_parser import MAX_INSTRUCTION_LENGTH, normalize_instruction


class _Request(BaseModel):
    model_config = ConfigDict(extra="forbid")


class CreateTaskRequest(_Request):
    instruction: str = Field(min_length=1, max_length=MAX_INSTRUCTION_LENGTH * 2)

    @field_validator("instruction")
    @classmethod
    def _normalize(cls, value: str) -> str:
        return normalize_instruction(value)


class ApprovalRequest(_Request):
    approved: bool


class ActionResultRequest(_Request):
    attempt: int = Field(ge=1, le=10)
    success: bool
    observation: str | None = Field(default=None, max_length=500)
    error: str | None = Field(default=None, max_length=500)
    retryable: bool = False
