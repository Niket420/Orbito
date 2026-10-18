"""LLM provider interface.

A provider turns an instruction into a raw plan dictionary of the shape
{"summary": str, "actions": [{"type": str, "parameters": {...}}],
 "unsupported_reason": str | None}. The planner validates it; providers
are never trusted.
"""

from __future__ import annotations

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
