"""Create and delete Hermes profiles (agents) for the phone. Spec: docs/agent-lifecycle.md.

Runs Hermes' own CLI in a separate process. Deleting notifies the running gateway
(the one Lekora lives in) over its control socket, which would deadlock if done
in-process; the CLI is also Hermes' stable, user-facing interface.

Delete safeguards: never ``default``; explicit ``confirm`` equal to the id; a
backup (Hermes export + Lekora chat history) in an app-owned folder must succeed
first; one operation at a time; Lekora's chat history is removed only after
Hermes confirms the delete.
"""

from __future__ import annotations

import asyncio
import json
import os
import re
import shutil
import sys
from dataclasses import asdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Awaitable, Callable, Optional, Sequence

from .profiles import DEFAULT_PROFILE_ID, discover_profiles
from .store import Store

CLI_TIMEOUT_SECONDS = 180.0
MAX_NAME_LENGTH = 64
BACKUP_DIR = Path("lekora-backups") / "profiles"

# (args) -> (exit code, combined output)
RunCli = Callable[[Sequence[str]], Awaitable[tuple[int, str]]]


class ProfileAdminError(Exception):
    """A refusal or failure with a wire error code (all recoverable)."""

    def __init__(self, code: str, reason: str) -> None:
        super().__init__(reason)
        self.code, self.reason = code, reason


def profile_id_for_name(name: str) -> str:
    """'Research Assistant' -> 'research-assistant' (Hermes: ^[a-z0-9][a-z0-9_-]{0,63}$)."""
    slug = re.sub(r"[^a-z0-9]+", "-", name.strip().lower()).strip("-")
    return slug[:MAX_NAME_LENGTH].rstrip("-")


def hermes_command() -> list[str]:
    """The `hermes` CLI of the same install the gateway runs from, else the one on PATH."""
    beside = Path(sys.executable).parent / "hermes"
    if beside.is_file() and os.access(beside, os.X_OK):
        return [str(beside)]
    found = shutil.which("hermes")
    if found:
        return [found]
    raise ProfileAdminError("PROFILE_OP_FAILED", "The hermes command was not found on this machine")


async def run_hermes_cli(args: Sequence[str]) -> tuple[int, str]:
    proc = await asyncio.create_subprocess_exec(
        *hermes_command(), *args,
        stdin=asyncio.subprocess.DEVNULL,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT)
    try:
        out, _ = await asyncio.wait_for(proc.communicate(), CLI_TIMEOUT_SECONDS)
    except asyncio.TimeoutError:
        proc.kill()
        await proc.wait()
        return 124, "timed out"
    return proc.returncode or 0, out.decode("utf-8", "replace")


def _last_line(output: str) -> str:
    lines = [line.strip() for line in output.splitlines() if line.strip()]
    return lines[-1][:200] if lines else "no output"


class ProfileAdmin:
    def __init__(self, store: Store, hermes_root: Callable[[], Path],
                 run_cli: RunCli = run_hermes_cli,
                 clock: Callable[[], datetime] = lambda: datetime.now(timezone.utc)) -> None:
        self._store = store
        self._root = hermes_root
        self._run = run_cli
        self._clock = clock
        self._lock = asyncio.Lock()

    def _profiles(self) -> list[dict]:
        return discover_profiles(self._root())

    def _find(self, profile_id: str) -> Optional[dict]:
        return next((p for p in self._profiles() if p["profile_id"] == profile_id), None)

    async def create(self, name: str, description: Optional[str] = None) -> dict:
        if not isinstance(name, str) or not name.strip():
            raise ProfileAdminError("INVALID_NAME", "Give the agent a name")
        profile_id = profile_id_for_name(name)
        if not profile_id:
            raise ProfileAdminError("INVALID_NAME", "Use letters or numbers in the agent's name")
        description = (description or "").strip() or None
        async with self._lock:
            if self._find(profile_id) is not None:
                raise ProfileAdminError("PROFILE_EXISTS", f"An agent called {profile_id!r} already exists")
            args = ["profile", "create", profile_id, "--clone-from", DEFAULT_PROFILE_ID, "--no-alias"]
            if description:
                args += ["--description", description]
            code, output = await self._run(args)
            if code != 0:
                raise ProfileAdminError("PROFILE_OP_FAILED", f"Hermes could not create the agent: {_last_line(output)}")
            created = self._find(profile_id)
            if created is None:
                raise ProfileAdminError("PROFILE_OP_FAILED", "Hermes reported success but the agent is not there")
            return created

    async def delete(self, profile_id: str, confirm: Optional[str]) -> str:
        """Returns the backup archive path, relative to the Hermes root."""
        if profile_id == DEFAULT_PROFILE_ID:
            raise ProfileAdminError("CANNOT_DELETE_DEFAULT", "The default agent can't be deleted")
        if not isinstance(confirm, str) or confirm != profile_id:
            raise ProfileAdminError("CONFIRMATION_REQUIRED", "Deleting an agent needs explicit confirmation")
        async with self._lock:
            if self._find(profile_id) is None:
                raise ProfileAdminError("UNKNOWN_PROFILE", f"There is no agent called {profile_id!r}")

            root = self._root()
            backups = root / BACKUP_DIR
            backups.mkdir(parents=True, exist_ok=True)
            os.chmod(backups, 0o700)  # the export contains the profile's keys
            stamp = self._clock().strftime("%Y%m%d-%H%M%S")
            archive = backups / f"{profile_id}-{stamp}.tar.gz"
            chat = backups / f"{profile_id}-{stamp}-lekora-chat.json"

            code, output = await self._run(["profile", "export", profile_id, "-o", str(archive)])
            if code != 0 or not archive.is_file() or archive.stat().st_size == 0:
                raise ProfileAdminError("BACKUP_FAILED",
                                        f"Backup failed, so nothing was deleted: {_last_line(output)}")
            try:
                events = [asdict(e) for e in self._store.events_for_profile(profile_id)]
                chat.write_text(json.dumps({"profile_id": profile_id, "events": events}, indent=1))
                os.chmod(chat, 0o600)
            except OSError as exc:
                raise ProfileAdminError("BACKUP_FAILED", f"Backup failed, so nothing was deleted: {exc}")

            code, output = await self._run(["profile", "delete", profile_id, "--yes"])
            if code != 0:
                raise ProfileAdminError("PROFILE_OP_FAILED",
                                        f"Hermes could not delete the agent (backup kept): {_last_line(output)}")
            self._store.delete_profile_events(profile_id)
            return str(archive.relative_to(root))
