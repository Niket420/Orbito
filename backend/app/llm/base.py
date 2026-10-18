"""LLM provider interface.

A provider turns an instruction into a raw plan dictionary of the shape
{"summary": str, "actions": [{"type": str, "parameters": {...}}],
 "unsupported_reason": str | None}. The planner validates it; providers
are never trusted.
"""

from __future__ import annotations

import json
import re
from typing import Any, Protocol


class LLMError(Exception):
    """Base class for provider failures. Messages are safe to show users."""

    retryable = False


class LLMAuthError(LLMError):
    pass


class LLMThrottledError(LLMError):
    retryable = True


class LLMTimeoutError(LLMError):
    retryable = True


class LLMUnavailableError(LLMError):
    pass


class LLMResponseError(LLMError):
    """The model replied, but not with a usable plan."""


class LLMProvider(Protocol):
    name: str

    def propose_plan(self, instruction: str) -> dict[str, Any]:
        """Blocking call; run it off the event loop."""
        ...


def json_object_from_text(text: str) -> dict[str, Any] | None:
    """Fallback for models that answer with JSON in prose instead of a tool call."""
    match = re.search(r"\{.*\}", text or "", re.S)
    if not match:
        return None
    try:
        value = json.loads(match.group(0))
    except json.JSONDecodeError:
        return None
    return value if isinstance(value, dict) else None
