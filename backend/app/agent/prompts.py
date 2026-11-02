"""Prompts and the structured-output tool definition for the planner LLM."""

from __future__ import annotations

from typing import Any

from app.policy.permissions import ACTION_SPECS
from app.policy.validator import MAX_ACTIONS

PLAN_TOOL_NAME = "propose_plan"


def _field_hint(prop: dict[str, Any]) -> str:
    """A short type hint for one parameter, e.g. "up|down", "int 1-30", "bool"."""
    if "anyOf" in prop:
        prop = next(p for p in prop["anyOf"] if p.get("type") != "null")
    if "enum" in prop:
        return "|".join(prop["enum"])
    kind = prop.get("type")
    if kind == "integer":
        return f"int {prop.get('minimum', '')}-{prop.get('maximum', '')}".replace(" -", " ").rstrip("-")
    if kind == "array":
        return "list"
    return {"boolean": "bool"}.get(kind, "text")


def _action_catalog() -> str:
    """One line per action: name(param: hint, optional?: hint): what it does."""
    lines = []
    for action_type, spec in ACTION_SPECS.items():
        schema = spec.params.model_json_schema()
        required = set(schema.get("required", []))
        fields = ", ".join(
            f"{name}{'' if name in required else '?'}: {_field_hint(prop)}"
            for name, prop in schema.get("properties", {}).items()
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
- You cannot run shell commands, enter passwords or payment details, send messages or
  emails, install software, empty the Trash, restart, shut down or log out. If the
  instruction needs anything outside the action list, return no actions and explain
  briefly in unsupported_reason.
- To close or quit an app, use close_application, never a keyboard shortcut.
  force_quit_application only when the user explicitly says force quit or the app is frozen.
- To go to an app that is already open ("switch to Chrome", "go back to Slack"), use
  switch_application; "switch back" / "previous app" leaves application_name out.
  Plain "go back" / "go forward" means app_command back / forward (the page, not the app).
- Prefer app_command over press_key for copy, paste, undo, save, tabs, back, reload and zoom.
- click_element needs the exact visible label of the button or link ("Sign in", "File").
- scroll moves the frontmost window; amount is in lines (about 5 for "a bit", 15 for "a lot").
- Questions about what's on screen, the selected text or the clipboard (summarize, explain,
  translate, define, "what does this say") use ask with the matching source. General
  questions you can answer yourself (maths, conversions, facts) use ask with source "none".
  The time, date, battery, storage and Wi-Fi come from get_info.
- Timers ("timer for 10 minutes") are create_reminder with in_minutes. Dates and times for
  reminders and events are local time as YYYY-MM-DDTHH:MM; work them out from the current
  local time given with the instruction.
- "Delete this file" means trash_selected_files (files selected in Finder).
- compose_email only opens a draft; the user sends it themselves.
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

# The action catalog in the system prompt lists each action's parameters; the schema
# stays small (it's sent with every request) and the validator checks the details.
_ACTION_SCHEMA = {
    "type": "object",
    "properties": {
        "type": {"type": "string", "enum": [t.value for t in ACTION_SPECS]},
        "parameters": {"type": "object"},
    },
    "required": ["type", "parameters"],
}

PLAN_TOOL_SCHEMA = {
    "type": "object",
    "properties": {
        "summary": {"type": "string", "description": "One short sentence for the user."},
        "actions": {
            "type": "array",
            "maxItems": MAX_ACTIONS,
            "items": _ACTION_SCHEMA,
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
