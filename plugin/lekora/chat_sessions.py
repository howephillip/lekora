"""Past chats (spec: docs/chats.md): each agent's conversations as Hermes keeps them.

Hermes starts a new conversation ("session") on /new, New Chat, or its own idle/daily reset,
and keeps every one with a title, a start and an end. Lekora groups the chat by them: every
message saved from now on carries the Hermes conversation it belongs to (``session``); earlier
ones are placed by time (the conversation running when they were saved). The phone shows the
current conversation and folds the rest away; an old one can be read, or continued with Hermes'
own ``/resume <id>``. Nothing is written to Hermes.
"""

from __future__ import annotations

import bisect
import logging
import time
from datetime import datetime, timezone
from typing import Any, Awaitable, Callable, Optional

log = logging.getLogger(__name__)

LIST_LIMIT = 200
CACHE_SECONDS = 30


def _ts(value: Any) -> Optional[float]:
    try:
        return float(value) if value is not None else None
    except (TypeError, ValueError):
        return None


def _event_time(created_at: Optional[str]) -> Optional[float]:
    if not created_at:
        return None
    try:
        return datetime.fromisoformat(created_at.replace("Z", "+00:00")).replace(tzinfo=timezone.utc).timestamp()
    except ValueError:
        return None


class ChatSessions:
    def __init__(self, store: Any,
                 list_sessions: Callable[[str, int], dict],
                 current_session: Callable[[str], Optional[str]],
                 send_command: Optional[Callable[[str, str], Awaitable[Any]]] = None) -> None:
        self.store = store
        self._list = list_sessions          # (profile, limit) -> {current, sessions: [Hermes rows]} (blocking)
        self._current = current_session    # profile -> the Hermes conversation now (fast, in memory)
        self.send_command = send_command   # (profile, text): a command handed to Hermes like a typed one
        self._cache: dict[str, tuple[float, dict]] = {}

    # ---- which conversation ----------------------------------------------------------

    def current(self, profile_id: str) -> Optional[str]:
        try:
            return self._current(profile_id)
        except Exception:
            log.debug("Lekora: couldn't read the current Hermes conversation", exc_info=True)
            return None

    def _sessions(self, profile_id: str, fresh: bool = False) -> dict:
        cached = self._cache.get(profile_id)
        if not fresh and cached and time.monotonic() - cached[0] < CACHE_SECONDS:
            return cached[1]
        try:
            got = self._list(profile_id, LIST_LIMIT) or {}
        except Exception:
            log.warning("Lekora: couldn't list %s's Hermes conversations", profile_id, exc_info=True)
            got = cached[1] if cached else {}
        self._cache[profile_id] = (time.monotonic(), got)
        return got

    def session_of(self, profile_id: str, payload: dict, created_at: Optional[str]) -> Optional[str]:
        """The conversation a saved message belongs to: its own tag, else by time."""
        tagged = payload.get("session")
        if isinstance(tagged, str) and tagged:
            return tagged
        sessions = self._sessions(profile_id).get("sessions") or []
        at = _event_time(created_at)
        if at is None or not sessions:
            return None
        starts = sorted((_ts(s.get("started_at")) or 0, s.get("id")) for s in sessions)
        index = bisect.bisect_right([start for start, _ in starts], at) - 1
        return starts[index][1] if index >= 0 else None

    # ---- for the phone -----------------------------------------------------------------

    def list(self, profile_id: str, query: str = "") -> dict:
        """Every conversation; with ``query``, only those whose title or messages contain it (with a snippet)."""
        query = " ".join(str(query or "").split()).lower()[:100]
        got = self._sessions(profile_id, fresh=True)
        current = self.current(profile_id) or got.get("current")
        counts: dict[str, int] = {}
        snippets: dict[str, str] = {}
        for event in self.store.events_for_profile(profile_id):
            if event.event_type != "chat.message" or event.payload.get("role") == "system":
                continue  # Hermes' own notices ("New session started") aren't the conversation
            session = self.session_of(profile_id, event.payload, event.created_at)
            if session:
                counts[session] = counts.get(session, 0) + 1
                if query and session not in snippets:
                    text = " ".join(str(event.payload.get("text") or event.payload.get("transcript") or "").split())
                    at = text.lower().find(query)
                    if at >= 0:
                        snippets[session] = ("…" if at > 40 else "") + text[max(at - 40, 0):at + len(query) + 60]
        chats = []
        for row in got.get("sessions") or []:
            sid = row.get("id")
            if not sid:
                continue
            if counts.get(sid, 0) == 0 and sid != current:
                continue  # an empty chat (e.g. New Chat pressed twice): nothing to look back at
            title_hit = query and query in " ".join(str(row.get(k) or "") for k in ("title", "preview")).lower()
            if query and not title_hit and sid not in snippets:
                continue
            chats.append({
                "session_id": sid,
                "title": (row.get("title") or "").strip() or None,
                "preview": (row.get("preview") or "").strip().strip('"')[:120] or None,
                "started_at": _ts(row.get("started_at")),
                "last_at": _ts(row.get("last_active")) or _ts(row.get("ended_at")) or _ts(row.get("started_at")),
                "messages": counts.get(sid, 0),
                "current": sid == current,
                **({"match": snippets[sid]} if sid in snippets else {}),
            })
        return {"current": current, "chats": chats}

    def messages(self, profile_id: str, session_id: str, limit: int = 500) -> list:
        """A past conversation's messages in Lekora (newest `limit`)."""
        events = [e for e in self.store.events_for_profile(profile_id)
                  if e.event_type == "chat.message" and self.session_of(profile_id, e.payload, e.created_at) == session_id]
        return events[-limit:]

    async def resume(self, profile_id: str, session_id: str) -> None:
        """Continue an earlier conversation: Hermes' own /resume, as if typed."""
        if self.send_command is None:
            raise RuntimeError("Hermes can't be asked from here")
        await self.send_command(profile_id, f"/resume {session_id}")
        self._cache.pop(profile_id, None)
