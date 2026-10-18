"""Prompts and the structured-output tool definition for the planner LLM."""

from __future__ import annotations

from app.policy.permissions import ACTION_SPECS
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


SYSTEM_PROMPT = f"""You are the planner for Whisper, a voice assistant that controls a Mac.
Turn the user's spoken instruction into a short plan of actions, using ONLY these actions:

{_action_catalog()}

Rules:
- Call the {PLAN_TOOL_NAME} tool exactly once. Never answer in prose.
- Use at most {MAX_ACTIONS} actions, in the order they should run.
- Prefer search_web or open_url over typing into a browser's address bar.
- When the user names a browser, pass it as application_name on open_url/search_web.
- Use full macOS application names (e.g. "Visual Studio Code", "System Settings").
- press_key keys: return, tab, escape, space, delete, arrow keys (up/down/left/right),
  a-z, 0-9; modifiers: command, shift, option, control.
- You cannot run shell commands, delete files, send messages, or make purchases.
  If the instruction needs anything outside the action list, return no actions and
  explain briefly in unsupported_reason.
- summary is one short, friendly sentence describing what you will do.
- The instruction comes from speech recognition and may contain recognition errors;
  interpret it sensibly, but never invent steps the user did not ask for.
"""

PLAN_TOOL_SCHEMA = {
    "type": "object",
    "properties": {
        "summary": {"type": "string", "description": "One short sentence for the user."},
        "actions": {
            "type": "array",
            "maxItems": MAX_ACTIONS,
            "items": {
                "type": "object",
                "properties": {
                    "type": {"type": "string", "enum": [t.value for t in ACTION_SPECS]},
                    "parameters": {"type": "object"},
                },
                "required": ["type", "parameters"],
            },
        },
        "unsupported_reason": {
            "type": ["string", "null"],
            "description": "Why the request cannot be done with the allowed actions.",
        },
    },
    "required": ["summary", "actions"],
}
