"""Lekora's tools for every agent, through the ``lekora`` command (docs/agent-command.md).

- ``AgentBridge``: a listener on 127.0.0.1 (a free port, a fresh token each start, both written to
  ``bridge.json`` readable only by this user) that runs a command's request exactly as the
  matching tool would, in the chat the command came from.
- ``install_command``: the ``lekora`` command in Lekora's own folder, pointing at this Python.
- ``ensure_skill``: Lekora's ``lekora-tools`` skill in an agent's skills folder, telling it how to
  run the command. Hermes lists it with the agent's other skills; the user can turn it off.
"""

from __future__ import annotations

import asyncio
import hmac
import json
import logging
import os
import secrets
import sys
from pathlib import Path
from typing import Awaitable, Callable, Optional

log = logging.getLogger(__name__)

MAX_REQUEST = 64 * 1024 * 1024
SKILL_NAME = "lekora-tools"
SKILL_CATEGORY = "lekora"
MANAGED_MARKER = ".lekora-managed"   # in the skill's folder: Lekora keeps it up to date
TOOLS = ("lekora_send_file", "lekora_create_artifact", "lekora_update_artifact", "lekora_edit_artifact",
         "lekora_read_artifact", "lekora_list_artifacts")

# tool, its arguments, the Hermes chat id the command came from -> the tool's JSON answer
Run = Callable[[str, dict, str], Awaitable[str]]


def _answer(ok: bool, **data) -> bytes:
    return json.dumps({"success": ok, **data}).encode() + b"\n"


def _write_private(path: Path, text: str, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    with os.fdopen(fd, "w") as f:
        f.write(text)
    os.chmod(tmp, mode)
    os.replace(tmp, path)


class AgentBridge:
    def __init__(self, folder: Path, run: Run) -> None:
        self.folder = Path(folder)
        self._run = run
        self._server: Optional[asyncio.base_events.Server] = None
        self._token = ""

    @property
    def info_path(self) -> Path:
        return self.folder / "bridge.json"

    async def start(self) -> int:
        self._token = secrets.token_urlsafe(32)
        self._server = await asyncio.start_server(self._serve, "127.0.0.1", 0, limit=MAX_REQUEST)
        port = self._server.sockets[0].getsockname()[1]
        _write_private(self.info_path, json.dumps({"port": port, "token": self._token}))
        return port

    async def stop(self) -> None:
        if self._server is not None:
            self._server.close()
            await self._server.wait_closed()
            self._server = None
        try:
            info = json.loads(self.info_path.read_text())
            if info.get("token") == self._token:
                self.info_path.unlink()
        except (OSError, ValueError):
            pass

    async def _serve(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        try:
            writer.write(await self._handle(await reader.readline()))
            await writer.drain()
        except Exception:
            log.debug("Lekora: a lekora command's request failed", exc_info=True)
        finally:
            writer.close()

    async def _handle(self, line: bytes) -> bytes:
        try:
            request = json.loads(line or b"{}")
        except ValueError:
            return _answer(False, error="Unreadable request")
        if not isinstance(request, dict) or not hmac.compare_digest(str(request.get("token") or ""), self._token):
            return _answer(False, error="Not allowed: Lekora restarted, or this isn't its command")
        tool, args, chat_id = request.get("tool"), request.get("args"), request.get("chat_id")
        if tool not in TOOLS or not isinstance(args, dict) or not isinstance(chat_id, str) or not chat_id:
            return _answer(False, error="Unknown request")
        log.info("Lekora: %s ran by command in chat %s", tool, chat_id)
        try:
            return (await self._run(tool, args, chat_id)).encode() + b"\n"
        except Exception as exc:
            return _answer(False, error=f"Couldn't do that: {getattr(exc, 'reason', None) or exc}")


def install_command(folder: Path, python: Optional[str] = None) -> str:
    """Writes the ``lekora`` command (a small launcher for agent_command.py with this Python);
    returns how to run it."""
    folder = Path(folder)
    python = python or sys.executable
    script = Path(__file__).resolve().parent / "agent_command.py"
    bridge = folder / "bridge.json"
    if os.name == "nt":
        path = folder / "lekora.cmd"
        _write_private(path, f'@"{python}" "{script}" --bridge "{bridge}" %*\r\n', 0o700)
        return f'"{path}"'
    path = folder / "lekora"
    _write_private(path, f'#!/bin/sh\nexec "{python}" "{script}" --bridge "{bridge}" "$@"\n', 0o700)
    return str(path) if " " not in str(path) else f'"{path}"'


def skill_text(command: str) -> str:
    """Lekora's skill for an agent: how to run the command (``command`` is its full path)."""
    c = command
    return f"""---
name: {SKILL_NAME}
description: "Lekora artifacts and sending files, from any agent"
version: 1.0.0
author: Lekora
---

# Lekora tools

Kept up to date by Lekora; changes here are replaced.

Use in a Lekora chat (the user talks to you in the Lekora app) whenever you make something the user should
see, keep or reuse — a page, report, plan, chart, diagram, tool or script — or the user asks for a file.
Make it an **artifact**: the user sees a card with a preview that opens full screen, and can edit it,
comment on lines, share it and go back to earlier versions. Don't paste long content into your reply or
just name a file path: the user can't open paths. Then say in a sentence what it is.

If you have the `lekora_create_artifact` and `lekora_send_file` tools, use them. Otherwise run these
commands with your terminal tool, from the conversation itself (they find the chat on their own, group
chats included). Each prints JSON: `"success"`, and the artifact's `artifact_id` or an `error`.

## Artifacts

Write the content to a file first, then:

```
{c} artifact create --title "Weekly plan" --kind html --file /path/plan.html
```

Kinds: `html` (one self-contained page; scripts and CDN libraries work), `markdown` (a document),
`code` (add `--language python`), `svg`, `text`, `mermaid` (a diagram), `react` (one JSX file with a
default-exported component; Tailwind classes work).

Anything a page should remember when the user changes it (ticked items, counts, inputs, settings) goes
in `localStorage`: Lekora keeps it, so it's still there the next time the card opens, on any phone.
Read it back when the page loads.

- List this chat's artifacts: `{c} artifact list`
- Read one (with the user's own edits): `{c} artifact read art_… [--version N]`
- Rewrite one (a new version; read it first, the user may have edited it):
  `{c} artifact update art_… --file /path/new.html --note "what changed"`
- Change parts (a new version):
  `{c} artifact edit art_… --edits '[{{"find": "old", "replace": "new"}}]' --note "fixed the title"`
  (or line edits: `{{"line_start": 3, "line_end": 4, "replacement": "..."}}`)

Never change an artifact by editing Lekora's files or database; the user won't see it.

## Files

Send any file on this machine (photo, PDF, spreadsheet, audio, video, up to 100 MB):

```
{c} send-file /path/report.pdf --caption "Here's the report"
```

Web pages, documents, code and text open as artifacts; audio plays in the chat.
"""


def ensure_skill(home: Path, command: str) -> bool:
    """Writes or refreshes Lekora's skill for the agent at ``home``; True when it changed. A skill of
    the same name that Lekora didn't make is left alone."""
    folder = Path(home) / "skills" / SKILL_CATEGORY / SKILL_NAME
    skill_md = folder / "SKILL.md"
    if skill_md.exists() and not (folder / MANAGED_MARKER).exists():
        return False
    text = skill_text(command)
    try:
        if skill_md.read_text() == text:
            return False
    except OSError:
        pass
    folder.mkdir(parents=True, exist_ok=True)
    (folder / MANAGED_MARKER).write_text("Lekora keeps this skill up to date.\n")
    tmp = folder / "SKILL.md.tmp"
    tmp.write_text(text)
    os.replace(tmp, skill_md)
    return True
