"""MOCK planner: a rule-based stand-in used when Bedrock is not configured.

It is reported as provider "mock" in /health and in every task so the UI can
label it. It understands only simple phrasings such as
"open Safari and search for AI news" or "go to apple.com".
"""

from __future__ import annotations

import re
from typing import Any

KNOWN_APPS = {
    "safari": "Safari",
    "chrome": "Google Chrome",
    "google chrome": "Google Chrome",
    "firefox": "Firefox",
    "vs code": "Visual Studio Code",
    "vscode": "Visual Studio Code",
    "visual studio code": "Visual Studio Code",
    "terminal": "Terminal",
    "notes": "Notes",
    "finder": "Finder",
    "mail": "Mail",
    "music": "Music",
    "calendar": "Calendar",
    "messages": "Messages",
    "system settings": "System Settings",
    "textedit": "TextEdit",
}
BROWSERS = {"Safari", "Google Chrome", "Firefox"}

_VERBS = r"(?:open|launch|start|search|google|look up|go to|visit|navigate to|type|press)"
_SPLIT = re.compile(rf"\s*,?\s*\b(?:and then|then|and)\s+(?={_VERBS}\b)", re.I)
_OPEN = re.compile(r"^(?:open|launch|start)\s+(?:up\s+)?(?:the\s+)?(?P<app>.+?)(?:\s+app)?$", re.I)
_SEARCH = re.compile(r"^(?:search|google|look up)\s+(?:the web\s+|online\s+)?(?:for\s+)?(?P<q>.+)$", re.I)
_VISIT = re.compile(r"^(?:go to|visit|navigate to)\s+(?P<url>\S+)$", re.I)
_TYPE = re.compile(r"^type\s+(?P<text>.+)$", re.I)
_PRESS = re.compile(r"^press\s+(?P<combo>[\w+\s]+)$", re.I)
_DOMAIN = re.compile(r"^[\w-]+(\.[\w-]+)+(/\S*)?$")


def _as_url(text: str) -> str:
    return text if text.startswith(("http://", "https://")) else f"https://{text}"


def _parse_combo(combo: str) -> dict[str, Any]:
    names = {"cmd": "command", "ctrl": "control", "alt": "option", "enter": "return", "esc": "escape"}
    parts = [names.get(p, p) for p in re.split(r"[+\s]+", combo.lower().strip()) if p]
    return {"key": parts[-1], "modifiers": parts[:-1]}


class MockLLMProvider:
    name = "mock"

    def propose_plan(self, instruction: str) -> dict[str, Any]:
        # Conversation history isn't understood by the rules; plan the current instruction.
        instruction = instruction.rpartition("Current instruction: ")[2]
        actions: list[dict[str, Any]] = []
        browser: str | None = None
        for clause in _SPLIT.split(instruction.strip().rstrip(".!?")):
            action = self._parse_clause(clause.strip(), browser)
            if action is None:
                return {
                    "summary": "",
                    "actions": [],
                    "unsupported_reason": (
                        "The mock planner only understands simple commands like "
                        "“open Safari and search for AI news”. Configure AWS Bedrock "
                        "for full understanding."
                    ),
                }
            if action["type"] == "open_application" and action["parameters"]["application_name"] in BROWSERS:
                browser = action["parameters"]["application_name"]
            actions.append(action)
        # No summary: the task manager then lists the validated step descriptions.
        return {"summary": "", "actions": actions, "unsupported_reason": None}

    def _parse_clause(self, clause: str, browser: str | None) -> dict[str, Any] | None:
        if m := _VISIT.match(clause):
            return self._open_url(_as_url(m["url"]), browser)
        if m := _SEARCH.match(clause):
            params = {"query": m["q"].strip()}
            if browser:
                params["application_name"] = browser
            return {"type": "search_web", "parameters": params}
        if m := _TYPE.match(clause):
            return {"type": "type_text", "parameters": {"text": m["text"].strip("\"'“”")}}
        if m := _PRESS.match(clause):
            return {"type": "press_key", "parameters": _parse_combo(m["combo"])}
        if m := _OPEN.match(clause):
            target = m["app"].strip()
            if _DOMAIN.match(target):
                return self._open_url(_as_url(target), browser)
            name = KNOWN_APPS.get(target.lower(), target.title())
            return {"type": "open_application", "parameters": {"application_name": name}}
        return None

    @staticmethod
    def _open_url(url: str, browser: str | None) -> dict[str, Any]:
        params = {"url": url}
        if browser:
            params["application_name"] = browser
        return {"type": "open_url", "parameters": params}
