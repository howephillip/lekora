"""Which Hermes tools an agent has in Lekora chats (spec: docs/agent-tools.md).

Lekora chats are their own Hermes platform ("lekora"). Until a list is saved for it, Hermes gives
them its default bundle, which leaves out default-off toolsets such as the task board (kanban);
an agent's choices for Telegram or the CLI don't carry over. This shows the agent's Lekora tools
and changes them with Hermes' own command (``hermes -p <agent> tools enable|disable … --platform
lekora``), which only writes ``platform_toolsets.lekora`` (Lekora's own platform entry) — after a
backup of the agent's config (rule 8). Nothing else in Hermes' config is touched.
"""

from __future__ import annotations

import asyncio
import logging
from pathlib import Path
from typing import Any, Awaitable, Callable, Optional, Sequence

log = logging.getLogger(__name__)

PLATFORM = "lekora"


class ToolsError(Exception):
    def __init__(self, code: str, reason: str) -> None:
        super().__init__(reason)
        self.code, self.reason = code, reason


class AgentTools:
    def __init__(self, read: Callable[[str], dict], run_cli: Callable[[Sequence[str]], Awaitable[tuple[int, str]]],
                 backup: Callable[[str], Optional[Path]]) -> None:
        self._read = read          # profile -> {toolsets: [{key, label, description, enabled}], elsewhere: {platform: [keys]}}
        self._run = run_cli
        self._backup = backup      # profile -> backup of its config.yaml
        self._lock = asyncio.Lock()

    async def get(self, profile_id: str) -> dict:
        return await asyncio.to_thread(self._read, profile_id)

    async def set(self, profile_id: str, changes: Any) -> dict:
        """``changes``: {toolset: on/off}. Returns the tools as Hermes now resolves them."""
        if not isinstance(changes, dict) or not changes:
            raise ToolsError("INVALID_SETTING", "Which tools?")
        async with self._lock:
            current = await self.get(profile_id)
            known = {t["key"]: t for t in current.get("toolsets", [])}
            unknown = [k for k in changes if k not in known]
            if unknown:
                raise ToolsError("INVALID_SETTING", f"Unknown tools: {', '.join(unknown)}")
            enable = sorted(k for k, on in changes.items() if on and not known[k]["enabled"])
            disable = sorted(k for k, on in changes.items() if not on and known[k]["enabled"])
            if not enable and not disable:
                return current
            try:
                await asyncio.to_thread(self._backup, profile_id)
            except Exception as exc:
                raise ToolsError("BACKUP_FAILED", f"Couldn't back up {profile_id}'s settings, so nothing changed: {exc}")
            for action, keys in (("enable", enable), ("disable", disable)):
                if not keys:
                    continue
                code, output = await self._run(["-p", profile_id, "tools", action, *keys, "--platform", PLATFORM])
                if code != 0:
                    raise ToolsError("TOOLS_FAILED", f"Hermes couldn't {action} {', '.join(keys)}: "
                                     + (output.strip().splitlines() or ["no details"])[-1])
            after = await self.get(profile_id)
            # Read back what Hermes now resolves, not the file: say so if a change didn't stick.
            state = {t["key"]: t["enabled"] for t in after.get("toolsets", [])}
            missed = [k for k in enable if not state.get(k)] + [k for k in disable if state.get(k)]
            if missed:
                after["problem"] = f"Hermes didn't apply: {', '.join(missed)}"
            return after
