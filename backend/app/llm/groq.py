"""Groq planner via its OpenAI-compatible Chat Completions API with forced tool calling.

The API key comes from GROQ_API_KEY (environment or backend/.env). It is only
sent in the Authorization header to api.groq.com and is never logged.
"""

from __future__ import annotations

import json
import logging
import time
from typing import Any

import httpx

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

BASE_URL = "https://api.groq.com/openai/v1"
MAX_ATTEMPTS = 3

_TOOL = {
    "type": "function",
    "function": {
        "name": PLAN_TOOL_NAME,
        "description": "Propose the plan of allowlisted Mac actions.",
        "parameters": PLAN_TOOL_SCHEMA,
    },
}


class GroqProvider:
    name = "groq"

    def __init__(
        self,
        api_key: str,
        model_id: str,
        timeout_seconds: float = 30,
        client: httpx.Client | None = None,
    ) -> None:
        self._model_id = model_id
        self._client = client or httpx.Client(
            base_url=BASE_URL,
            timeout=httpx.Timeout(timeout_seconds, connect=5),
            headers={"Authorization": f"Bearer {api_key}"},
        )

    def propose_plan(self, instruction: str) -> dict[str, Any]:
        body = {
            "model": self._model_id,
            "messages": [
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": instruction},
            ],
            "tools": [_TOOL],
            "tool_choice": {"type": "function", "function": {"name": PLAN_TOOL_NAME}},
            "temperature": 0,
            "max_completion_tokens": 1024,
        }
        for attempt in range(1, MAX_ATTEMPTS + 1):
            response = self._post(body)
            retryable = response.status_code == 429 or response.status_code >= 500
            if not retryable or attempt == MAX_ATTEMPTS:
                break
            time.sleep(_retry_delay(response, attempt))
        return _parse(response)

    def _post(self, body: dict[str, Any]) -> httpx.Response:
        try:
            return self._client.post("/chat/completions", json=body)
        except httpx.TimeoutException:
            raise LLMTimeoutError("Groq took too long to respond.") from None
        except httpx.HTTPError:
            raise LLMUnavailableError("Couldn't reach Groq. Check your internet connection.") from None


def _retry_delay(response: httpx.Response, attempt: int) -> float:
    try:
        return min(float(response.headers.get("retry-after", "")), 5.0)
    except ValueError:
        return min(0.5 * 2**attempt, 4.0)


def _parse(response: httpx.Response) -> dict[str, Any]:
    status = response.status_code
    if status != 200:
        try:
            error = response.json().get("error", {})
        except ValueError:
            error = {}
        code = error.get("code") or error.get("type") or ""
        log.warning("groq_error", extra={"status": status, "code": code})
        if status in (401, 403):
            raise LLMAuthError("Groq rejected the API key. Check GROQ_API_KEY in backend/.env.")
        if status == 404 or code == "model_not_found":
            raise LLMUnavailableError("The configured Groq model wasn't found. Check ORBITO_GROQ_MODEL_ID.")
        if status == 429:
            raise LLMThrottledError("Groq's rate limit was reached. Please try again shortly.")
        if status >= 500:
            raise LLMUnavailableError("Groq is temporarily unavailable.")
        if code == "tool_use_failed":
            raise LLMResponseError("The model didn't produce a valid plan. Try rephrasing.")
        raise LLMError(f"Groq rejected the planning request ({code or status}).")

    try:
        message = response.json()["choices"][0]["message"]
    except (ValueError, KeyError, IndexError, TypeError):
        raise LLMResponseError("Groq returned an unexpected response.") from None

    for call in message.get("tool_calls") or []:
        function = call.get("function") or {}
        if function.get("name") == PLAN_TOOL_NAME:
            try:
                plan = json.loads(function.get("arguments") or "")
            except json.JSONDecodeError:
                raise LLMResponseError("The model's plan wasn't valid JSON.") from None
            if isinstance(plan, dict):
                return plan
            raise LLMResponseError("The model's plan was not a JSON object.")

    plan = json_object_from_text(message.get("content") or "")
    if plan is None:
        raise LLMResponseError("The model didn't return a usable plan.")
    return plan
