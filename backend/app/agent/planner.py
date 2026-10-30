"""Turns an instruction into a validated plan via the configured LLM provider."""

from __future__ import annotations

import asyncio
import logging
import os

from app.config import Settings
from app.llm.base import LLMProvider, LLMUnavailableError
from app.llm.mock import MockLLMProvider
from app.policy.validator import PlanValidationError, ValidatedPlan, validate_plan

log = logging.getLogger(__name__)


class Planner:
    def __init__(self, llm: LLMProvider) -> None:
        self.llm = llm

    @property
    def provider_name(self) -> str:
        return self.llm.name

    async def plan(self, instruction: str, history: str | None = None) -> ValidatedPlan:
        """Ask the LLM for a plan and validate it. Raises LLMError or PlanValidationError.

        `history` describes earlier turns of the same conversation, so references like
        "close it" can be resolved. A rejected plan gets one retry, with the validator's
        error passed back so the model can correct it. The retry is validated just as strictly.
        """
        if history:
            instruction = f"Earlier in this conversation:\n{history}\n\nCurrent instruction: {instruction}"
        raw = await asyncio.to_thread(self.llm.propose_plan, instruction)
        try:
            plan = validate_plan(raw)
        except PlanValidationError as exc:
            log.warning("plan_rejected_retrying", extra={"provider": self.llm.name, "error": str(exc)})
            correction = (
                f"{instruction}\n\n[Your previous plan was rejected: {exc} "
                "Return a corrected plan with every required parameter filled in.]"
            )
            raw = await asyncio.to_thread(self.llm.propose_plan, correction)
            plan = validate_plan(raw)
        log.info(
            "plan_validated",
            extra={"provider": self.llm.name, "actions": [a.type.value for a in plan.actions]},
        )
        return plan


def _bedrock(settings: Settings) -> LLMProvider:
    from app.llm.bedrock import BedrockProvider, credentials_available

    if settings.bedrock_api_key and not os.environ.get("AWS_BEARER_TOKEN_BEDROCK"):
        # boto3 reads Bedrock API keys only from this environment variable.
        os.environ["AWS_BEARER_TOKEN_BEDROCK"] = settings.bedrock_api_key.get_secret_value()
    if not settings.bedrock_model_id:
        raise LLMUnavailableError("ORBITO_BEDROCK_MODEL_ID is not set")
    if not credentials_available():
        raise LLMUnavailableError("no AWS credentials found")
    return BedrockProvider(settings.bedrock_model_id, settings.aws_region, settings.bedrock_timeout_seconds)


def _groq(settings: Settings) -> LLMProvider:
    from app.llm.groq import GroqProvider

    if not settings.groq_api_key:
        raise LLMUnavailableError("GROQ_API_KEY is not set")
    if not settings.groq_model_id:
        raise LLMUnavailableError("ORBITO_GROQ_MODEL_ID is not set")
    return GroqProvider(
        settings.groq_api_key.get_secret_value(), settings.groq_model_id, settings.groq_timeout_seconds
    )


_PROVIDERS = {"bedrock": _bedrock, "groq": _groq}


def build_llm_provider(settings: Settings) -> LLMProvider:
    """Use the configured provider; in "auto", the first fully configured one, else the labelled mock."""
    if settings.llm_provider == "mock":
        return MockLLMProvider()

    names = list(_PROVIDERS) if settings.llm_provider == "auto" else [settings.llm_provider]
    reasons = {}
    for name in names:
        try:
            return _PROVIDERS[name](settings)
        except LLMUnavailableError as exc:
            reasons[name] = str(exc)

    if settings.llm_provider != "auto":
        raise RuntimeError(f"{settings.llm_provider} is required but unavailable: {reasons}")
    log.warning("llm_fallback_to_mock", extra={"reasons": reasons})
    return MockLLMProvider()
