"""Group chats run by Lekora (docs/group-chats.md).

A group is a name and member agents. On the phone it is one chat, ``group:<id>``. In Hermes each
member has its own chat for the group, ``g.<id>.<profile>``, routed to that profile, which keeps
that agent's own memory of the group. A user message goes to every addressed member at once; each
gets what was said since its last turn, then the new message. Replies of exactly ``(pass)`` are
dropped; a reply that @mentions a member brings it in, within the loop guard. Nothing here imports
Hermes.
"""

from __future__ import annotations

import asyncio
import logging
import re
import threading
import uuid
from dataclasses import dataclass, field
from typing import Any, Awaitable, Callable, Iterable, Optional

log = logging.getLogger(__name__)

KEY_PREFIX = "group:"
CHAT_PREFIX = "g."
MIN_MEMBERS = 2
MAX_NAME = 60
CATCH_UP = 30            # messages given at most, newest last
LINE_LIMIT = 2000        # characters of one message in a catch-up
MAX_ROUNDS = 3           # agents bringing each other in, per user message
MAX_AGENT_MESSAGES = 10  # agent messages per user message
EVERYONE = {"all", "everyone"}
PASS = "(pass)"
_MENTION = re.compile(r"@([A-Za-z0-9][A-Za-z0-9._-]*)")

# (Hermes chat id, profile id, text, message id, files) -> None: hands a turn to an agent
Deliver = Callable[[str, str, str, str, list], Awaitable[None]]


class GroupError(Exception):
    def __init__(self, code: str, reason: str) -> None:
        super().__init__(reason)
        self.code = code
        self.reason = reason


def is_pass(text: Any) -> bool:
    return str(text or "").strip().lower() in (PASS, "pass", "")


def may_be_pass(text: Any) -> bool:
    """Still possibly a ``(pass)`` while it's being written: not shown yet."""
    words = str(text or "").strip().lower()
    return PASS.startswith(words) or "pass".startswith(words)


@dataclass
class _Exchange:
    """What one user message set off: the loop guard's counts."""
    user_seq: int
    agent_messages: int = 0
    rounds: dict[str, int] = field(default_factory=dict)  # member -> the round it was brought in at


class Groups:
    def __init__(self, store: Any, profiles: Callable[[], list[dict]], deliver: Optional[Deliver] = None,
                 changed: Optional[Callable[[list[dict]], Awaitable[None]]] = None,
                 user_name: Callable[[], str] = lambda: "The user") -> None:
        self.store = store
        self._profiles = profiles
        self.deliver = deliver
        self._changed = changed
        self._user_name = user_name
        self._exchanges: dict[str, _Exchange] = {}
        self._seen_lock = threading.Lock()  # members' catch-ups are made at the same time

    # ---- names --------------------------------------------------------------

    @staticmethod
    def key(group_id: str) -> str:
        return KEY_PREFIX + group_id

    @staticmethod
    def chat(group_id: str, profile_id: str) -> str:
        return f"{CHAT_PREFIX}{group_id}.{profile_id}"

    @staticmethod
    def is_key(value: Any) -> bool:
        return isinstance(value, str) and value.startswith(KEY_PREFIX)

    def parse_chat(self, chat_id: Any) -> Optional[tuple[str, str]]:
        """``(group id, profile id)`` for a member's Hermes chat of a group, else None."""
        if not isinstance(chat_id, str) or not chat_id.startswith(CHAT_PREFIX):
            return None
        group_id, _, profile_id = chat_id[len(CHAT_PREFIX):].partition(".")
        if not group_id or not profile_id:
            return None
        group = self.store.get_group(group_id)
        return (group_id, profile_id) if group is not None and profile_id in group["members"] else None

    def phone(self, chat_id: str) -> tuple[str, Optional[str]]:
        """The phone's chat for a Hermes chat, and who spoke (None outside groups)."""
        parsed = self.parse_chat(chat_id)
        return (self.key(parsed[0]), parsed[1]) if parsed else (chat_id, None)

    def group_for_key(self, key: Any) -> Optional[dict]:
        return self.store.get_group(key[len(KEY_PREFIX):]) if self.is_key(key) else None

    def member_chats(self) -> list[tuple[str, str]]:
        """Every member's Hermes chat of every group, with its profile (for routing)."""
        return [(self.chat(g["group_id"], p), p) for g in self.store.list_groups() for p in g["members"]]

    # ---- the phone's changes ---------------------------------------------------

    def _names(self) -> dict[str, str]:
        return {p["profile_id"]: p.get("name") or p["profile_id"] for p in self._profiles()}

    def _clean(self, name: Any, members: Any) -> tuple[str, list[str]]:
        name = " ".join(str(name or "").split())[:MAX_NAME]
        if not name:
            raise GroupError("INVALID_GROUP", "Give the group a name")
        if not isinstance(members, list) or not all(isinstance(m, str) for m in members):
            raise GroupError("INVALID_GROUP", "Members must be agents")
        known = self._names()
        members = list(dict.fromkeys(members))
        unknown = [m for m in members if m not in known]
        if unknown:
            raise GroupError("INVALID_GROUP", f"Unknown agent: {', '.join(unknown)}")
        if len(members) < MIN_MEMBERS:
            raise GroupError("INVALID_GROUP", "A group needs at least two agents")
        return name, members

    @staticmethod
    def wire(group: dict) -> dict:
        return {k: group[k] for k in ("group_id", "name", "members", "created_at")}

    def list(self) -> list[dict]:
        return [self.wire(g) for g in self.store.list_groups()]

    def _require(self, group_id: Any) -> dict:
        group = self.store.get_group(str(group_id or ""))
        if group is None:
            raise GroupError("UNKNOWN_GROUP", "That group doesn't exist any more")
        return group

    async def create(self, name: Any, members: Any) -> dict:
        name, members = self._clean(name, members)
        group_id = "g" + uuid.uuid4().hex[:10]
        await asyncio.to_thread(self.store.add_group, group_id, name, members)
        await self._announce()
        return self.wire(self._require(group_id))

    async def update(self, group_id: Any, name: Any = None, members: Any = None) -> dict:
        group = self._require(group_id)
        name, members = self._clean(group["name"] if name is None else name,
                                    group["members"] if members is None else members)
        seen = {p: s for p, s in group["seen"].items() if p in members}
        # A newcomer starts from now: it gets the conversation from its next turn on.
        await asyncio.to_thread(self.store.update_group, group["group_id"], name=name, members=members, seen=seen)
        await self._announce()
        return self.wire(self._require(group["group_id"]))

    async def delete(self, group_id: Any) -> str:
        group = self._require(group_id)
        await asyncio.to_thread(self.store.delete_group, group["group_id"], self.key(group["group_id"]))
        self._exchanges.pop(group["group_id"], None)
        await self._announce()
        return group["group_id"]

    async def agent_removed(self, profile_id: str) -> None:
        """An agent was deleted: it leaves its groups."""
        touched = False
        for group in self.store.list_groups():
            if profile_id in group["members"]:
                members = [m for m in group["members"] if m != profile_id]
                await asyncio.to_thread(self.store.update_group, group["group_id"], members=members)
                touched = True
        if touched:
            await self._announce()

    async def _announce(self) -> None:
        if self._changed is not None:
            await self._changed(self.list())

    # ---- turns --------------------------------------------------------------

    def addressed(self, group: dict, text: str, exclude: Iterable[str] = ()) -> list[str]:
        """The members ``text`` @mentions (by profile id, or by name without spaces); everyone when
        nobody is, or for @all / @everyone. ``exclude``: never these (the one speaking)."""
        names = self._names()
        handles: dict[str, str] = {}
        for member in group["members"]:
            handles[member.lower()] = member
            handles["".join(names.get(member, member).split()).lower()] = member
        said = [m.lower().rstrip(".") for m in _MENTION.findall(text or "")]
        excluded = set(exclude)
        if any(m in EVERYONE for m in said):
            return [m for m in group["members"] if m not in excluded]
        picked = [handles[m] for m in said if m in handles]
        return [m for m in dict.fromkeys(picked) if m not in excluded]

    async def user_said(self, key: str, seq: int, text: str, files: Optional[list] = None) -> list[str]:
        """The user's message to a group: every addressed member gets its turn, all at once."""
        group = self.group_for_key(key)
        if group is None or len(group["members"]) < MIN_MEMBERS:
            return []
        targets = self.addressed(group, text) or list(group["members"])
        self._exchanges[group["group_id"]] = _Exchange(seq, rounds={m: 0 for m in targets})
        await asyncio.gather(*(self._turn(group, m, seq, files or []) for m in targets))
        return targets

    async def agent_said(self, chat_id: str, seq: int, text: str) -> list[str]:
        """An agent's saved reply in a group: members it @mentions are brought in, within the guard."""
        parsed = self.parse_chat(chat_id)
        if parsed is None:
            return []
        group_id, speaker = parsed
        group = self._require(group_id)
        exchange = self._exchanges.get(group_id)
        if exchange is None:
            return []
        exchange.agent_messages += 1
        round_ = exchange.rounds.get(speaker, 0) + 1
        mentioned = self.addressed(group, text, exclude=[speaker]) if _MENTION.search(text or "") else []
        if not mentioned or round_ > MAX_ROUNDS or exchange.agent_messages >= MAX_AGENT_MESSAGES:
            return []
        for member in mentioned:
            exchange.rounds[member] = round_
        await asyncio.gather(*(self._turn(group, m, seq, []) for m in mentioned))
        return mentioned

    async def _turn(self, group: dict, member: str, upto: int, files: list) -> None:
        if self.deliver is None:
            return
        text = await asyncio.to_thread(self.catch_up, group["group_id"], member, upto)
        try:
            await self.deliver(self.chat(group["group_id"], member), member, text,
                               f"lekora-group-{uuid.uuid4().hex[:12]}", files)
        except Exception:
            log.exception("Lekora: couldn't give %s its turn in group %s", member, group["group_id"])

    def catch_up(self, group_id: str, member: str, upto: int) -> str:
        """What ``member`` is handed: who's here, then what was said since its last turn (its own
        words left out), the newest last. Remembers how far it has been given."""
        with self._seen_lock:
            return self._catch_up(group_id, member, upto)

    def _catch_up(self, group_id: str, member: str, upto: int) -> str:
        group = self._require(group_id)
        names = self._names()
        user = self._user_name() or "The user"
        seen = int(group["seen"].get(member, 0))
        events = [e for e in self.store.messages_after(self.key(group_id), seen, CATCH_UP * 3) if e.seq <= upto]
        lines = []
        for event in events:
            line = self._line(event.payload, names, user)
            if line and event.payload.get("speaker") != member:
                lines.append(line)
        lines = lines[-CATCH_UP:]
        others = [f"@{m} ({names.get(m, m)})" for m in group["members"] if m != member]
        head = (f'[Group chat "{group["name"]}" in Lekora. You are @{member}. '
                f'Also here: {", ".join(others)} and {user} (the user).]')
        group["seen"][member] = max(seen, upto)
        self.store.update_group(group_id, seen=group["seen"])
        return head + "\n\n" + "\n\n".join(lines) if lines else head

    @staticmethod
    def _line(payload: dict, names: dict[str, str], user: str) -> Optional[str]:
        role = payload.get("role")
        text = str(payload.get("text") or "").strip()
        extras = []
        if payload.get("files"):
            extras.append("sent " + ", ".join(f.get("name", "a file") for f in payload["files"]))
        if payload.get("artifact"):
            extras.append(f'shared the artifact "{payload["artifact"].get("title", "")}"')
        if not text and not extras:
            return None
        if len(text) > LINE_LIMIT:
            text = text[:LINE_LIMIT - 1].rstrip() + "…"
        body = " ".join(filter(None, [text, f"({'; '.join(extras)})" if extras else ""]))
        if role == "user":
            return f"{user}: {body}"
        speaker = payload.get("speaker")
        if role in ("assistant", "agent") and speaker:
            return f"@{speaker} ({names.get(speaker, speaker)}): {body}"
        return None
