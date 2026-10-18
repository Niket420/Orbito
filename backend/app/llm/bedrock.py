"""AWS Bedrock planner using the model-agnostic Converse API with tool use.

Credentials come only from the standard AWS provider chain (environment,
shared config/SSO profile, instance role). They are never read, logged or
returned by this module.
"""

from __future__ import annotations

import logging
import os
from typing import Any

import boto3
from botocore.config import Config
from botocore.exceptions import (
    BotoCoreError,
    ClientError,
    ConnectTimeoutError,
    EndpointConnectionError,
    NoCredentialsError,
    NoRegionError,
    PartialCredentialsError,
    ReadTimeoutError,
)

from app.agent.prompts import PLAN_TOOL_NAME, PLAN_TOOL_SCHEMA, SYSTEM_PROMPT
from app.llm.base import (
    LLMAuthError,
    LLMError,
    LLMResponseError,
    LLMThrottledError,
    LLMTimeoutError,
    LLMUnavailableError,
    json_object_from_text,
)

log = logging.getLogger(__name__)

_AUTH_CODES = {
    "AccessDeniedException",
    "UnrecognizedClientException",
    "ExpiredTokenException",
    "InvalidSignatureException",
}
_THROTTLE_CODES = {"ThrottlingException", "ServiceQuotaExceededException", "TooManyRequestsException"}
_UNAVAILABLE_CODES = {"ServiceUnavailableException", "InternalServerException", "ModelNotReadyException"}

_TOOL_CONFIG = {
    "tools": [
        {
            "toolSpec": {
                "name": PLAN_TOOL_NAME,
                "description": "Propose the plan of allowlisted Mac actions.",
                "inputSchema": {"json": PLAN_TOOL_SCHEMA},
            }
        }
    ],
}


def credentials_available() -> bool:
    if os.environ.get("AWS_BEARER_TOKEN_BEDROCK"):
        return True  # Bedrock API key
    try:
        return boto3.Session().get_credentials() is not None
    except BotoCoreError:
        return False


class BedrockProvider:
    name = "bedrock"

    def __init__(
        self,
        model_id: str,
        region: str | None,
        timeout_seconds: float = 30,
        client: Any | None = None,
    ) -> None:
        self._model_id = model_id
        if client is not None:
            self._client = client
            return
        try:
            self._client = boto3.client(
                "bedrock-runtime",
                region_name=region,
                config=Config(
                    connect_timeout=5,
                    read_timeout=timeout_seconds,
                    retries={"max_attempts": 3, "mode": "adaptive"},
                ),
            )
        except NoRegionError:
            raise LLMUnavailableError(
                "No AWS region configured. Set AWS_REGION for Bedrock."
            ) from None

    def propose_plan(self, instruction: str) -> dict[str, Any]:
        request = {
            "modelId": self._model_id,
            "system": [{"text": SYSTEM_PROMPT}],
            "messages": [{"role": "user", "content": [{"text": instruction}]}],
            "toolConfig": {**_TOOL_CONFIG, "toolChoice": {"any": {}}},
            "inferenceConfig": {"maxTokens": 1024, "temperature": 0},
        }
        try:
            response = self._converse(request)
        except LLMResponseError as exc:
            # Some Bedrock models do not support toolChoice; retry without it.
            if "toolChoice" not in str(exc.__cause__ or ""):
                raise
            request["toolConfig"] = dict(_TOOL_CONFIG)
            response = self._converse(request)
        return extract_plan(response)

    def _converse(self, request: dict[str, Any]) -> dict[str, Any]:
        try:
            return self._client.converse(**request)
        except (NoCredentialsError, PartialCredentialsError):
            raise LLMAuthError("AWS credentials are not configured for Bedrock.") from None
        except ClientError as exc:
            code = exc.response.get("Error", {}).get("Code", "")
            log.warning("bedrock_client_error", extra={"code": code})
            if code in _AUTH_CODES:
                raise LLMAuthError(
                    "Bedrock rejected the AWS credentials or model access. "
                    "Check your AWS profile and that the model is enabled."
                ) from None
            if code in _THROTTLE_CODES:
                raise LLMThrottledError("Bedrock is busy right now. Please try again shortly.") from None
            if code in _UNAVAILABLE_CODES:
                raise LLMUnavailableError("Bedrock is temporarily unavailable.") from None
            if code == "ResourceNotFoundException":
                raise LLMUnavailableError("The configured Bedrock model ID was not found.") from None
            if code == "ValidationException":
                raise LLMResponseError("Bedrock rejected the planning request.") from exc
            raise LLMError(f"Bedrock request failed ({code or 'unknown error'}).") from None
        except (ReadTimeoutError, ConnectTimeoutError):
            raise LLMTimeoutError("Bedrock took too long to respond.") from None
        except EndpointConnectionError:
            raise LLMUnavailableError("Couldn't reach Bedrock. Check your internet connection.") from None
        except BotoCoreError as exc:
            raise LLMError(f"Bedrock request failed ({type(exc).__name__}).") from None


def extract_plan(response: Any) -> dict[str, Any]:
    """Pull the plan out of a Converse response (tool call, or JSON text fallback)."""
    try:
        content = response["output"]["message"]["content"]
    except (KeyError, TypeError):
        raise LLMResponseError("Bedrock returned an unexpected response.") from None

    for block in content:
        tool_use = block.get("toolUse") if isinstance(block, dict) else None
        if tool_use and tool_use.get("name") == PLAN_TOOL_NAME:
            plan = tool_use.get("input")
            if isinstance(plan, dict):
                return plan
            raise LLMResponseError("The model's plan was not a JSON object.")

    text = "".join(b.get("text", "") for b in content if isinstance(b, dict))
    plan = json_object_from_text(text)
    if plan is None:
        raise LLMResponseError("The model didn't return a usable plan.")
    return plan
