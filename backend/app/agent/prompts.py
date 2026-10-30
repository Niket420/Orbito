"""Prompts and the structured-output tool definition for the planner LLM."""

from __future__ import annotations

from typing import Any

from pydantic import BaseModel

from app.policy.permissions import (
    ACTION_SPECS,
    ALLOWED_KEYS,
    ALLOWED_MODIFIERS,
    ActionType,
    PressKeyParams,
)
from app.policy.validator import MAX_ACTIONS

PLAN_TOOL_NAME = "propose_plan"


def _action_catalog() -> str:
    lines = []
    for action_type, spec in ACTION_SPECS.items():
        fields = ", ".join(
            f"{name}{'' if field.is_required() else '?'}"
            for name, field in spec.params.model_fields.items()
        )
        lines.append(f"- {action_type.value}({fields}): {spec.summary}")
    return "\n".join(lines)


SYSTEM_PROMPT = f"""You are the planner for Orbito, a voice assistant that controls a Mac.
Turn the user's spoken instruction into a short plan of actions, using ONLY these actions:

{_action_catalog()}

Rules:
- Call the {PLAN_TOOL_NAME} tool exactly once. Never answer in prose.
- Use at most {MAX_ACTIONS} actions, in the order they should run.
- Prefer search_web or open_url over typing into a browser's address bar.
- When the user names a browser, pass it as application_name on open_url/search_web.
- Every action must include all of its required parameters. For example, "open Chrome"
  is {{"type": "open_application", "parameters": {{"application_name": "Google Chrome"}}}}.
- Use full macOS application names (e.g. "Visual Studio Code", "System Settings").
- press_key keys: return, tab, escape, space, delete, arrow keys (up/down/left/right),
  a-z, 0-9; modifiers: command, shift, option, control.
- You cannot run shell commands, delete files, send messages, or make purchases.
  If the instruction needs anything outside the action list, return no actions and
  explain briefly in unsupported_reason.
- To close or quit an app, use close_application, never a keyboard shortcut.
- scroll moves the frontmost window; amount is in lines (about 5 for "a bit", 15 for "a lot").
- Earlier turns of the conversation may be given before the instruction. Use them only to
  understand references such as "it", "that app" or "again", and plan only the current
  instruction.
- Speech is captured hands-free, so some of it isn't meant for you (background talk, a
  phone call, an unfinished phrase). If it isn't a request to do something on the Mac,
  set not_a_command to true and return no actions.
- summary is one short, friendly sentence describing what you will do.
- The instruction comes from speech recognition and may contain recognition errors;
  interpret it sensibly, but never invent steps the user did not ask for.
"""

def _parameters_schema(params_model: type[BaseModel]) -> dict[str, Any]:
    """JSON Schema for one action's parameters, derived from its Pydantic model."""
    schema = params_model.model_json_schema()
    properties = {}
    for name, prop in schema.get("properties", {}).items():
        prop = {k: v for k, v in prop.items() if k not in ("title", "default")}
        if "anyOf" in prop:  # Optional[X]: describe X; optionality comes from "required"
            inner = next(p for p in prop.pop("anyOf") if p.get("type") != "null")
            prop = {**inner, **prop}
        properties[name] = prop
    if params_model is PressKeyParams:
        properties["key"]["enum"] = sorted(ALLOWED_KEYS)
        properties["modifiers"]["items"] = {"type": "string", "enum": sorted(ALLOWED_MODIFIERS)}
    return {
        "type": "object",
        "properties": properties,
        "required": schema.get("required", []),
        "additionalProperties": False,
    }


def _action_schema(action_type: ActionType) -> dict[str, Any]:
    spec = ACTION_SPECS[action_type]
    return {
        "type": "object",
        "description": spec.summary,
        "properties": {
            "type": {"type": "string", "enum": [action_type.value]},
            "parameters": _parameters_schema(spec.params),
        },
        "required": ["type", "parameters"],
        "additionalProperties": False,
    }


# Each action spells out its exact parameters, so the model can't leave required ones out.
PLAN_TOOL_SCHEMA = {
    "type": "object",
    "properties": {
        "summary": {"type": "string", "description": "One short sentence for the user."},
        "actions": {
            "type": "array",
            "maxItems": MAX_ACTIONS,
            "items": {"anyOf": [_action_schema(t) for t in ACTION_SPECS]},
        },
        "unsupported_reason": {
            "type": ["string", "null"],
            "description": "Why the request cannot be done with the allowed actions.",
        },
        "not_a_command": {
            "type": "boolean",
            "description": "True if the speech is not a request for the Mac (ignore it).",
        },
    },
    "required": ["summary", "actions"],
}
