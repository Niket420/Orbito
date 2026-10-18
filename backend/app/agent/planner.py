"""Turns an instruction into a validated plan via the configured LLM provider."""

from __future__ import annotations

import asyncio
import logging

from app.config import Settings
from app.llm.base import LLMProvider, LLMUnavailableError
from app.llm.mock import MockLLMProvider
from app.policy.validator import ValidatedPlan, validate_plan

log = logging.getLogger(__name__)


class Planner:
    def __init__(self, llm: LLMProvider) -> None:
        self.llm = llm

    @property
    def provider_name(self) -> str:
        return self.llm.name

    async def plan(self, instruction: str) -> ValidatedPlan:
        """Ask the LLM for a plan and validate it. Raises LLMError or PlanValidationError."""
        raw = await asyncio.to_thread(self.llm.propose_plan, instruction)
        plan = validate_plan(raw)
        log.info(
            "plan_validated",
            extra={"provider": self.llm.name, "actions": [a.type.value for a in plan.actions]},
        )
        return plan


def build_llm_provider(settings: Settings) -> LLMProvider:
    """Choose Bedrock when configured; otherwise the explicitly labelled mock."""
    if settings.llm_provider == "mock":
        return MockLLMProvider()

    from app.llm.bedrock import BedrockProvider, credentials_available

    reason = None
    if not settings.bedrock_model_id:
        reason = "WHISPER_BEDROCK_MODEL_ID is not set"
    elif not credentials_available():
        reason = "no AWS credentials found"

    if reason is None:
        try:
            return BedrockProvider(
                settings.bedrock_model_id,
                settings.aws_region,
                settings.bedrock_timeout_seconds,
            )
        except LLMUnavailableError as exc:
            reason = str(exc)

    if settings.llm_provider == "bedrock":
        raise RuntimeError(f"Bedrock is required but unavailable: {reason}")
    log.warning("llm_fallback_to_mock", extra={"reason": reason})
    return MockLLMProvider()
