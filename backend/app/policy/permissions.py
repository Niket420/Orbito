"""The allowlist of actions the assistant may perform, with risk levels.

This is the single source of truth for what an LLM plan is allowed to contain.
Anything not listed here is rejected by the validator, regardless of what the
LLM proposes.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from enum import Enum
from typing import Callable, Literal
from urllib.parse import urlparse

from pydantic import BaseModel, ConfigDict, Field, field_validator


class ActionType(str, Enum):
    OPEN_APPLICATION = "open_application"
    OPEN_URL = "open_url"
    SEARCH_WEB = "search_web"
    TYPE_TEXT = "type_text"
    PRESS_KEY = "press_key"
    CLOSE_APPLICATION = "close_application"
    SCROLL = "scroll"
    SWITCH_APPLICATION = "switch_application"
    HIDE_APPLICATION = "hide_application"
    FORCE_QUIT_APPLICATION = "force_quit_application"
    WINDOW_CONTROL = "window_control"
    APP_COMMAND = "app_command"
    CLICK_ELEMENT = "click_element"
    ASK = "ask"
    TAKE_SCREENSHOT = "take_screenshot"
    OPEN_LOCATION = "open_location"
    FIND_FILE = "find_file"
    CREATE_FOLDER = "create_folder"
    TRASH_SELECTED_FILES = "trash_selected_files"
    SYSTEM_CONTROL = "system_control"
    OPEN_SETTINGS = "open_settings"
    GET_INFO = "get_info"
    MEDIA_CONTROL = "media_control"
    PLAY_MEDIA = "play_media"
    CREATE_NOTE = "create_note"
    CREATE_REMINDER = "create_reminder"
    LIST_EVENTS = "list_events"
    CREATE_EVENT = "create_event"
    COMPOSE_EMAIL = "compose_email"
    SET_CLIPBOARD = "set_clipboard"


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


class ScrollParams(_Params):
    direction: Literal["up", "down", "left", "right"]
    amount: int = Field(default=5, ge=1, le=30, description="How far to scroll, in lines.")


class SwitchApplicationParams(_Params):
    application_name: str | None = Field(
        default=None, max_length=80, description="Leave out to switch back to the previous app."
    )

    _name = field_validator("application_name")(_check_app_name)


class HideApplicationParams(_Params):
    application_name: str = Field(min_length=1, max_length=80)
    others: bool = Field(default=False, description="True hides every other app instead.")

    _name = field_validator("application_name")(_check_app_name)


class WindowControlParams(_Params):
    operation: Literal[
        "minimize", "maximize", "fullscreen", "left_half", "right_half", "top_half",
        "bottom_half", "center", "close", "next_display",
    ]


# Named commands, so common shortcuts need no approval (the app maps them to keys).
APP_COMMANDS = (
    "copy", "cut", "paste", "select_all", "undo", "redo", "save", "find", "new_tab",
    "close_tab", "reopen_tab", "next_tab", "previous_tab", "back", "forward", "reload",
    "new_window", "address_bar", "zoom_in", "zoom_out", "actual_size",
)


class AppCommandParams(_Params):
    command: Literal[APP_COMMANDS]  # type: ignore[valid-type]


# Buttons whose names suggest something hard to undo always ask first.
RISKY_CLICK_WORDS = (
    "delete", "remove", "erase", "trash", "buy", "pay", "purchase", "order", "checkout",
    "send", "submit", "post", "publish", "confirm", "transfer", "sign out", "log out",
    "uninstall", "unsubscribe", "discard", "reset", "format",
)


class ClickElementParams(_Params):
    target: str = Field(
        min_length=1, max_length=80, description="Visible name of the button, link, tab or menu item."
    )

    def is_risky(self) -> bool:
        target = self.target.lower()
        return any(word in target for word in RISKY_CLICK_WORDS)


class AskParams(_Params):
    question: str = Field(min_length=1, max_length=300)
    source: Literal["screen", "selection", "clipboard", "none"] = Field(
        default="none", description="What to read before answering."
    )


class ScreenshotParams(_Params):
    area: Literal["full", "window", "selection"] = "full"
    destination: Literal["file", "clipboard"] = "file"


LOCATIONS = (
    "home", "desktop", "documents", "downloads", "applications", "pictures", "music",
    "movies", "trash", "icloud_drive",
)
_FILE_NAME = re.compile(r"^[^/:\x00]{1,120}$")


def _check_file_name(value: str | None) -> str | None:
    if value is not None and (not _FILE_NAME.fullmatch(value) or value.startswith(".")):
        raise ValueError("must be a plain file or folder name")
    return value


class OpenLocationParams(_Params):
    location: Literal[LOCATIONS]  # type: ignore[valid-type]
    subfolder: str | None = Field(default=None, max_length=120, description="A folder inside location.")

    _sub = field_validator("subfolder")(_check_file_name)


class FindFileParams(_Params):
    query: str = Field(min_length=1, max_length=120, description="Part of the file name.")
    open: bool = Field(default=False, description="Open the best match instead of listing matches.")


class CreateFolderParams(_Params):
    name: str = Field(min_length=1, max_length=120)
    location: Literal[LOCATIONS] = "desktop"  # type: ignore[valid-type]

    _name = field_validator("name")(_check_file_name)


class NoParams(_Params):
    pass


SYSTEM_CONTROLS = (
    "volume_up", "volume_down", "set_volume", "mute", "unmute", "brightness_up",
    "brightness_down", "dark_mode_on", "dark_mode_off", "wifi_on", "wifi_off",
    "lock_screen", "sleep",
)
RISKY_SYSTEM_CONTROLS = frozenset({"wifi_off", "lock_screen", "sleep"})


class SystemControlParams(_Params):
    control: Literal[SYSTEM_CONTROLS]  # type: ignore[valid-type]
    value: int | None = Field(
        default=None, ge=0, le=100, description="Volume level for set_volume; step size otherwise."
    )


SETTINGS_PANES = (
    "general", "wifi", "bluetooth", "network", "sound", "displays", "battery",
    "notifications", "focus", "appearance", "wallpaper", "desktop_dock", "keyboard",
    "trackpad", "privacy", "accessibility", "users", "storage", "software_update",
)


class OpenSettingsParams(_Params):
    pane: Literal[SETTINGS_PANES]  # type: ignore[valid-type]


class GetInfoParams(_Params):
    item: Literal["battery", "storage", "wifi", "time", "date", "running_apps", "clipboard", "front_app"]


class MediaControlParams(_Params):
    command: Literal["play_pause", "next", "previous"]


class PlayMediaParams(_Params):
    query: str = Field(min_length=1, max_length=200)
    app: Literal["spotify", "apple_music", "youtube"] = "youtube"


class CreateNoteParams(_Params):
    model_config = ConfigDict(extra="forbid")
    text: str = Field(min_length=1, max_length=2000)


_LOCAL_DATETIME = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$")


def _check_datetime(value: str | None) -> str | None:
    if value is not None and not _LOCAL_DATETIME.fullmatch(value):
        raise ValueError("must be local time as YYYY-MM-DDTHH:MM")
    return value


class CreateReminderParams(_Params):
    title: str = Field(min_length=1, max_length=200)
    in_minutes: int | None = Field(default=None, ge=1, le=10080, description="Remind after this many minutes.")
    due: str | None = Field(default=None, description="Local time, YYYY-MM-DDTHH:MM.")

    _due = field_validator("due")(_check_datetime)


class ListEventsParams(_Params):
    day: Literal["today", "tomorrow"] = "today"


class CreateEventParams(_Params):
    title: str = Field(min_length=1, max_length=200)
    start: str = Field(description="Local time, YYYY-MM-DDTHH:MM.")
    duration_minutes: int = Field(default=60, ge=5, le=1440)

    _start = field_validator("start")(_check_datetime)


_EMAIL = re.compile(r"^[^@\s,;<>]+@[^@\s,;<>]+\.[^@\s,;<>]+$")


class ComposeEmailParams(_Params):
    to: list[str] = Field(default_factory=list, max_length=5)
    subject: str | None = Field(default=None, max_length=200)
    body: str | None = Field(default=None, max_length=2000)

    @field_validator("to")
    @classmethod
    def _emails(cls, value: list[str]) -> list[str]:
        for address in value:
            if not _EMAIL.fullmatch(address):
                raise ValueError(f"'{address}' is not an email address")
        return value


class SetClipboardParams(_Params):
    model_config = ConfigDict(extra="forbid")
    text: str = Field(min_length=1, max_length=2000)


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
    # Risk that depends on the parameters (e.g. a "Delete" button); defaults to `risk`.
    risk_of: Callable[[_Params], Risk] | None = None
    # The step's observation (or an answer computed from it) is the task's result.
    answers: bool = False

    def risk_for(self, params: _Params) -> Risk:
        return self.risk_of(params) if self.risk_of else self.risk


def _pretty(value: str) -> str:
    return value.replace("_", " ")


_SETTINGS_NAMES = {"wifi": "Wi-Fi", "desktop_dock": "Desktop & Dock", "software_update": "Software Update"}


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
    # Quits normally, so apps still ask to save unsaved work. Force quit stays impossible.
    ActionType.CLOSE_APPLICATION: ActionSpec(
        OpenApplicationParams,
        Risk.LOW,
        retry_safe=True,
        summary="Quit an open application normally (it can still ask to save changes).",
        describe=lambda p: f"Close {p.application_name}",
    ),
    ActionType.SCROLL: ActionSpec(
        ScrollParams,
        Risk.LOW,
        retry_safe=False,
        summary="Scroll the frontmost window up, down, left or right.",
        describe=lambda p: f"Scroll {p.direction}",
    ),
    ActionType.SWITCH_APPLICATION: ActionSpec(
        SwitchApplicationParams,
        Risk.LOW,
        retry_safe=True,
        summary="Bring an open app to the front; leave application_name out to go back to the previous app.",
        describe=lambda p: f"Switch to {p.application_name}" if p.application_name else "Switch to the previous app",
    ),
    ActionType.HIDE_APPLICATION: ActionSpec(
        HideApplicationParams,
        Risk.LOW,
        retry_safe=True,
        summary="Hide an app, or with others=true hide every app except it.",
        describe=lambda p: f"Hide apps other than {p.application_name}" if p.others else f"Hide {p.application_name}",
    ),
    ActionType.FORCE_QUIT_APPLICATION: ActionSpec(
        OpenApplicationParams,
        Risk.CONFIRM,
        retry_safe=True,
        summary="Force quit a frozen app (unsaved work is lost). Only when the user says force quit.",
        describe=lambda p: f"Force quit {p.application_name}",
    ),
    ActionType.WINDOW_CONTROL: ActionSpec(
        WindowControlParams,
        Risk.LOW,
        retry_safe=False,
        summary="Minimize, maximize, full-screen, tile, centre, close or move the front window to the next display.",
        describe=lambda p: f"Window: {_pretty(p.operation)}",
    ),
    ActionType.APP_COMMAND: ActionSpec(
        AppCommandParams,
        Risk.LOW,
        retry_safe=False,
        summary="Run a standard command in the front app: copy, paste, undo, save, find, tabs, back, reload, zoom…",
        describe=lambda p: _pretty(p.command).capitalize(),
    ),
    ActionType.CLICK_ELEMENT: ActionSpec(
        ClickElementParams,
        Risk.LOW,
        retry_safe=False,
        summary="Click a button, link, tab, checkbox or menu item in the front app by its visible name.",
        describe=lambda p: f"Click {_quote(p.target)}",
        risk_of=lambda p: Risk.CONFIRM if p.is_risky() else Risk.LOW,
    ),
    ActionType.ASK: ActionSpec(
        AskParams,
        Risk.LOW,
        retry_safe=True,
        summary=(
            "Answer a question, optionally after reading the screen, the selected text or the "
            "clipboard (summarize, explain, translate, define, calculate)."
        ),
        describe=lambda p: "Read the screen" if p.source == "screen" else (
            f"Read the {p.source}" if p.source != "none" else "Answer"),
        answers=True,
    ),
    ActionType.TAKE_SCREENSHOT: ActionSpec(
        ScreenshotParams,
        Risk.LOW,
        retry_safe=False,
        summary="Take a screenshot of the full screen, the front window or a selected area, to a file or the clipboard.",
        describe=lambda p: "Take a screenshot" + (" of the window" if p.area == "window" else ""),
    ),
    ActionType.OPEN_LOCATION: ActionSpec(
        OpenLocationParams,
        Risk.LOW,
        retry_safe=True,
        summary="Open a standard folder (optionally a subfolder inside it) in Finder.",
        describe=lambda p: f"Open {p.subfolder or _pretty(p.location).title()}",
    ),
    ActionType.FIND_FILE: ActionSpec(
        FindFileParams,
        Risk.LOW,
        retry_safe=True,
        summary="Find files in the home folder by name with Spotlight; open=true opens the best match.",
        describe=lambda p: f"{'Open' if p.open else 'Find'} {_quote(p.query)}",
        answers=True,
    ),
    ActionType.CREATE_FOLDER: ActionSpec(
        CreateFolderParams,
        Risk.LOW,
        retry_safe=True,
        summary="Create a new folder in a standard location.",
        describe=lambda p: f"Create folder {_quote(p.name)}",
    ),
    ActionType.TRASH_SELECTED_FILES: ActionSpec(
        NoParams,
        Risk.CONFIRM,
        retry_safe=False,
        summary="Move the files currently selected in Finder to the Trash.",
        describe=lambda p: "Move the selected Finder items to the Trash",
    ),
    ActionType.SYSTEM_CONTROL: ActionSpec(
        SystemControlParams,
        Risk.LOW,
        retry_safe=False,
        summary="Change volume, brightness, dark mode or Wi-Fi, lock the screen or put the Mac to sleep.",
        describe=lambda p: (f"Set volume to {p.value}%" if p.control == "set_volume" and p.value is not None
                            else _pretty(p.control).capitalize().replace("Wifi", "Wi-Fi")),
        risk_of=lambda p: Risk.CONFIRM if p.control in RISKY_SYSTEM_CONTROLS else Risk.LOW,
    ),
    ActionType.OPEN_SETTINGS: ActionSpec(
        OpenSettingsParams,
        Risk.LOW,
        retry_safe=True,
        summary="Open a System Settings pane.",
        describe=lambda p: f"Open {_SETTINGS_NAMES.get(p.pane, _pretty(p.pane).title())} settings",
    ),
    ActionType.GET_INFO: ActionSpec(
        GetInfoParams,
        Risk.LOW,
        retry_safe=True,
        summary="Report battery, free storage, Wi-Fi, the time or date, open apps, the clipboard or the front app.",
        describe=lambda p: f"Check the {_pretty(p.item)}",
        answers=True,
    ),
    ActionType.MEDIA_CONTROL: ActionSpec(
        MediaControlParams,
        Risk.LOW,
        retry_safe=False,
        summary="Play/pause, next or previous track in whatever is playing.",
        describe=lambda p: {"play_pause": "Play/pause", "next": "Next track", "previous": "Previous track"}[p.command],
    ),
    ActionType.PLAY_MEDIA: ActionSpec(
        PlayMediaParams,
        Risk.LOW,
        retry_safe=False,
        summary="Search for a song, artist or video in Spotify, Apple Music or YouTube.",
        describe=lambda p: f"Find {_quote(p.query)} on {_pretty(p.app).title().replace('Youtube', 'YouTube')}",
    ),
    ActionType.CREATE_NOTE: ActionSpec(
        CreateNoteParams,
        Risk.LOW,
        retry_safe=False,
        summary="Create a note in Notes (first line becomes the title).",
        describe=lambda p: f"New note {_quote(p.text.splitlines()[0], 40)}",
    ),
    ActionType.CREATE_REMINDER: ActionSpec(
        CreateReminderParams,
        Risk.LOW,
        retry_safe=False,
        summary="Add a reminder, optionally due in N minutes or at a time. Also use this for timers.",
        describe=lambda p: f"Remind me: {_quote(p.title, 40)}"
        + (f" in {p.in_minutes} min" if p.in_minutes else f" at {p.due.replace('T', ' ')}" if p.due else ""),
    ),
    ActionType.LIST_EVENTS: ActionSpec(
        ListEventsParams,
        Risk.LOW,
        retry_safe=True,
        summary="List today's or tomorrow's Calendar events.",
        describe=lambda p: f"Check {p.day}'s calendar",
        answers=True,
    ),
    ActionType.CREATE_EVENT: ActionSpec(
        CreateEventParams,
        Risk.CONFIRM,
        retry_safe=False,
        summary="Add an event to Calendar.",
        describe=lambda p: f"Add event {_quote(p.title, 40)} at {p.start.replace('T', ' ')}",
    ),
    ActionType.COMPOSE_EMAIL: ActionSpec(
        ComposeEmailParams,
        Risk.LOW,
        retry_safe=False,
        summary="Open a new email draft in the default mail app (never sends it).",
        describe=lambda p: "Draft an email" + (f" to {', '.join(p.to)}" if p.to else ""),
    ),
    ActionType.SET_CLIPBOARD: ActionSpec(
        SetClipboardParams,
        Risk.LOW,
        retry_safe=True,
        summary="Put text on the clipboard.",
        describe=lambda p: f"Copy {_quote(p.text, 40)}",
    ),
}
