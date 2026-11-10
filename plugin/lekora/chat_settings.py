"""Per-chat settings (spec: docs/chat-settings.md).

Changes go through Hermes' own commands, handed to the agent's chat as if typed
("/reasoning high", "/fast on", "/yolo"…), so Hermes applies them its own way and
answers in the chat. This module turns the app's requests into those commands and
checks them; reading the current values is ``hermes_settings.py`` (Hermes internals).
"""

from __future__ import annotations

import re
from typing import Any, Awaitable, Callable, Optional

REASONING = ("none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra", "reset")
FAST = ("normal", "fast", "auto", "ultrafast")
APPROVALS = ("manual", "smart", "off")
ACTIONS = {"new": "/new", "compress": "/compress", "undo": "/undo", "retry": "/retry"}
MAX_TITLE = 100


class SettingsError(Exception):
    def __init__(self, code: str, reason: str) -> None:
        super().__init__(reason)
        self.code, self.reason = code, reason


def command_for(key: str, value: Any, current: Optional[dict] = None) -> Optional[str]:
    """The Hermes command for a change, or None when it's already set (e.g. YOLO already on)."""
    current = current or {}
    if key == "reasoning":
        if value not in REASONING:
            raise SettingsError("INVALID_SETTING", "Unknown reasoning level")
        return f"/reasoning {value}"
    if key == "show_reasoning":
        return "/reasoning show" if bool(value) else "/reasoning hide"
    if key == "fast":
        if value not in FAST:
            raise SettingsError("INVALID_SETTING", "Unknown fast mode")
        return f"/fast {value}"
    if key == "yolo":
        # /yolo toggles: only send it when the state actually changes.
        if current.get("yolo") is not None and bool(current["yolo"]) == bool(value):
            return None
        return "/yolo"
    if key == "personality":
        name = str(value or "none")
        options = (current.get("personality") or {}).get("options")
        if name != "none" and options is not None and name not in {o.get("name") for o in options}:
            raise SettingsError("INVALID_SETTING", "Unknown personality")
        if not re.fullmatch(r"[\w.-]+", name):
            raise SettingsError("INVALID_SETTING", "Unknown personality")
        return f"/personality {name}"
    if key == "approvals":
        if value not in APPROVALS:
            raise SettingsError("INVALID_SETTING", "Unknown approval mode")
        return f"/approvals {value}"
    if key == "title":
        title = " ".join(str(value or "").split())[:MAX_TITLE]
        if not title:
            raise SettingsError("INVALID_SETTING", "Give the chat a name")
        return f"/title {title}"
    raise SettingsError("INVALID_SETTING", "Unknown setting")


class ChatSettings:
    def __init__(self, read: Callable[[str], dict],
                 send_command: Callable[[str, str], Awaitable[Any]]) -> None:
        self._read = read                    # profile id -> current settings (blocking)
        self._send_command = send_command    # (profile id, command) -> handed to Hermes

    def read(self, profile_id: str) -> dict:
        return self._read(profile_id)

    async def change(self, profile_id: str, key: str, value: Any, current: Optional[dict] = None) -> dict:
        command = command_for(key, value, current)
        if command is not None:
            await self._send_command(profile_id, command)
        return {"key": key, "command": command}

    async def act(self, profile_id: str, action: str) -> dict:
        command = ACTIONS.get(action)
        if command is None:
            raise SettingsError("INVALID_SETTING", "Unknown action")
        await self._send_command(profile_id, command)
        return {"action": action, "command": command}
