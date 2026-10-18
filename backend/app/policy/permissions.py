"""The allowlist of actions the assistant may perform, with risk levels.

This is the single source of truth for what an LLM plan is allowed to contain.
Anything not listed here is rejected by the validator, regardless of what the
LLM proposes.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from enum import Enum
from typing import Callable
from urllib.parse import urlparse

from pydantic import BaseModel, ConfigDict, Field, field_validator


class ActionType(str, Enum):
    OPEN_APPLICATION = "open_application"
    OPEN_URL = "open_url"
    SEARCH_WEB = "search_web"
    TYPE_TEXT = "type_text"
    PRESS_KEY = "press_key"


class Risk(str, Enum):
    LOW = "low"  # runs automatically
    CONFIRM = "confirm"  # requires explicit user approval


_APP_NAME = re.compile(r"^[\w][\w .&'+\-]{0,79}$")


class _Params(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)


def _check_app_name(value: str | None) -> str | None:
    if value is not None and not _APP_NAME.fullmatch(value):
        raise ValueError("application_name contains unsupported characters")
    return value


class OpenApplicationParams(_Params):
    application_name: str = Field(min_length=1, max_length=80)

    _name = field_validator("application_name")(_check_app_name)


class OpenURLParams(_Params):
    url: str = Field(min_length=1, max_length=2048)
    application_name: str | None = Field(default=None, max_length=80)

    _name = field_validator("application_name")(_check_app_name)

    @field_validator("url")
    @classmethod
    def _http_only(cls, value: str) -> str:
        parsed = urlparse(value)
        if parsed.scheme not in {"http", "https"} or not parsed.netloc:
            raise ValueError("url must be an http(s) URL")
        return value


class SearchWebParams(_Params):
    query: str = Field(min_length=1, max_length=300)
    application_name: str | None = Field(default=None, max_length=80)

    _name = field_validator("application_name")(_check_app_name)


class TypeTextParams(_Params):
    model_config = ConfigDict(extra="forbid")  # keep whitespace the user asked for
    text: str = Field(min_length=1, max_length=500)


ALLOWED_KEYS = frozenset(
    {"return", "tab", "escape", "space", "delete", "up", "down", "left", "right"}
    | set("abcdefghijklmnopqrstuvwxyz0123456789")
)
ALLOWED_MODIFIERS = frozenset({"command", "shift", "option", "control"})

# Shortcuts that quit, log out, lock, force-quit or delete are never allowed.
BLOCKED_SHORTCUTS = frozenset(
    {
        frozenset({"command", "q"}),
        frozenset({"command", "option", "escape"}),
        frozenset({"control", "command", "q"}),
        frozenset({"command", "shift", "q"}),
        frozenset({"command", "option", "shift", "q"}),
        frozenset({"command", "delete"}),
        frozenset({"command", "shift", "delete"}),
        frozenset({"command", "option", "shift", "delete"}),
    }
)


class PressKeyParams(_Params):
    key: str
    modifiers: list[str] = Field(default_factory=list, max_length=3)

    @field_validator("key")
    @classmethod
    def _known_key(cls, value: str) -> str:
        value = value.lower()
        if value not in ALLOWED_KEYS:
            raise ValueError(f"key '{value}' is not supported")
        return value

    @field_validator("modifiers")
    @classmethod
    def _known_modifiers(cls, value: list[str]) -> list[str]:
        value = sorted({m.lower() for m in value})
        unknown = set(value) - ALLOWED_MODIFIERS
        if unknown:
            raise ValueError(f"unsupported modifiers: {sorted(unknown)}")
        return value

    def is_blocked(self) -> bool:
        return frozenset({*self.modifiers, self.key}) in BLOCKED_SHORTCUTS


def _quote(text: str, limit: int = 60) -> str:
    return f"“{text if len(text) <= limit else text[: limit - 1] + '…'}”"


_KEY_GLYPHS = {"command": "⌘", "shift": "⇧", "option": "⌥", "control": "⌃"}


def _describe_key(p: PressKeyParams) -> str:
    glyphs = "".join(_KEY_GLYPHS[m] for m in p.modifiers)
    return f"Press {glyphs}{p.key.upper() if len(p.key) == 1 else p.key.capitalize()}"


@dataclass(frozen=True)
class ActionSpec:
    params: type[_Params]
    risk: Risk
    # Safe to repeat after a failure without duplicate side effects.
    retry_safe: bool
    summary: str
    describe: Callable[[_Params], str]


ACTION_SPECS: dict[ActionType, ActionSpec] = {
    ActionType.OPEN_APPLICATION: ActionSpec(
        OpenApplicationParams,
        Risk.LOW,
        retry_safe=True,
        summary="Launch or bring to front an installed application by name.",
        describe=lambda p: f"Open {p.application_name}",
    ),
    ActionType.OPEN_URL: ActionSpec(
        OpenURLParams,
        Risk.LOW,
        retry_safe=False,
        summary="Open an http(s) URL, optionally in a specific browser.",
        describe=lambda p: f"Open {urlparse(p.url).netloc}",
    ),
    ActionType.SEARCH_WEB: ActionSpec(
        SearchWebParams,
        Risk.LOW,
        retry_safe=False,
        summary="Run a web search for a query, optionally in a specific browser.",
        describe=lambda p: f"Search the web for {_quote(p.query)}",
    ),
    ActionType.TYPE_TEXT: ActionSpec(
        TypeTextParams,
        Risk.CONFIRM,
        retry_safe=False,
        summary="Type text into the currently focused field.",
        describe=lambda p: f"Type {_quote(p.text)}",
    ),
    ActionType.PRESS_KEY: ActionSpec(
        PressKeyParams,
        Risk.CONFIRM,
        retry_safe=False,
        summary="Press a key, optionally with modifiers (e.g. command+t).",
        describe=_describe_key,
    ),
}
