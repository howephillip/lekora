"""Approval and question cards (spec: docs/prompts.md).

Hermes pauses an agent to ask for permission (risky commands) or to ask a question
(the clarify tool). The Hermes adapter hands those requests here; each becomes a card,
saved in the chat as a message with role "approval" or "question" and a ``card`` object,
so it survives restarts and reaches every phone. An answer from a phone is passed to
Hermes through its own resolve functions (given as ``Resolvers``, so this module has no
Hermes imports and is tested with fakes), and the card is updated for every phone.

Cards that can no longer be answered are closed with a reason: Hermes timed out the
approval, retired the question, the turn ended, the user answered by typing, or Hermes
restarted (on startup, leftovers from a previous run are marked expired).
"""

from __future__ import annotations

import asyncio
import json
import logging
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Any, Awaitable, Callable, Optional

log = logging.getLogger(__name__)

APPROVAL_CHOICES = ("once", "session", "always", "deny")
APPROVAL_STATUS = {"once": "allowed_once", "session": "allowed_session",
                   "always": "allowed_always", "deny": "denied"}
# Confirmations of slash commands such as /new (Hermes' slash_confirm).
CONFIRM_CHOICES = ("once", "always", "cancel")
CONFIRM_STATUS = {"once": "confirmed_once", "always": "confirmed_always", "cancel": "cancelled"}
CONFIRM_TIMEOUT = 300  # Hermes drops a confirmation after this many seconds
CARD_MESSAGE_PREFIX = "card-"  # the message id Hermes gets back (and edits on timeout)
MAX_REASON = 280               # Hermes caps a denial reason at this length
MAX_ANSWER = 2000


class PromptError(Exception):
    def __init__(self, code: str, reason: str) -> None:
        super().__init__(reason)
        self.code, self.reason = code, reason


@dataclass
class Resolvers:
    """Hermes' own functions, injected (fakes in tests).

    approve(session_key, choice, reason) -> how many waiting approvals it resolved (0 = none)
    answer(clarify_id, text) -> False if Hermes no longer waits for that question
    approval_timeout() -> seconds Hermes waits for an answer, or None if unknown
    waiting(kind, session_key, clarify_id) -> whether Hermes still waits on such a request
        (None = can't tell; then the card is closed when its turn ends)
    """
    approve: Callable[[str, str, Optional[str]], int] = lambda session_key, choice, reason: 0
    answer: Callable[[str, str], bool] = lambda clarify_id, text: False
    approval_timeout: Callable[[], Optional[int]] = lambda: None
    waiting: Callable[[str, str, Optional[str]], Optional[bool]] = lambda kind, session_key, clarify_id: None
    # confirm(session_key, confirm_id, choice) -> (ran, text to show): a slash-command confirmation
    confirm: Callable[[str, str, str], Awaitable[tuple[bool, Optional[str]]]] = None  # type: ignore[assignment]

    def __post_init__(self) -> None:
        if self.confirm is None:
            async def nothing(session_key: str, confirm_id: str, choice: str) -> tuple[bool, Optional[str]]:
                return False, None
            self.confirm = nothing


@dataclass
class _Live:
    """A card Hermes is waiting on in this run."""
    seq: int
    chat_id: str
    kind: str                      # "approval" | "question" | "confirm"
    session_key: str
    card: dict
    clarify_id: Optional[str] = None   # a question's clarify id, or a confirmation's confirm id
    choices: list[str] = field(default_factory=list)  # a question's options, as Hermes has them


def _iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _plain_title(title: str) -> str:
    """"⚠️ **Confirm /new**" -> "Confirm /new"."""
    return _one_line(str(title or "").replace("**", "").replace("⚠️", "").replace("⚠", "")) or "Confirm"


def _confirm_detail(message: str) -> str:
    """What the command will do, from Hermes' prompt: without its title line, its
    "Choose: …" list and its "Text fallback" line (the card has buttons for those)."""
    parts = [p.strip() for p in str(message or "").split("\n\n") if p.strip()]
    if parts and (parts[0].startswith(("⚠", "**")) and "confirm" in parts[0].lower()):
        parts = parts[1:]
    kept = []
    for part in parts:
        if part.lower().startswith(("choose:", "_text fallback", "text fallback")):
            break
        kept.append(part)
    return "\n\n".join(kept)


def _one_line(text: str, limit: int = 120) -> str:
    line = " ".join(str(text or "").split())
    return line if len(line) <= limit else line[: limit - 1] + "…"


class Prompts:
    def __init__(self, gateway: Callable[[], Any], resolvers: Optional[Resolvers] = None,
                 clock: Callable[[], datetime] = lambda: datetime.now(timezone.utc)) -> None:
        self._gateway = gateway
        self.resolvers = resolvers or Resolvers()
        self._clock = clock
        self._live: dict[str, _Live] = {}
        # After a typed message, Hermes needs a moment to act on it before cards are rechecked.
        self.recheck_delay = 1.5
        self._tasks: set[asyncio.Task] = set()

    def _gw(self) -> Any:
        gw = self._gateway()
        if gw is None:
            raise RuntimeError("Lekora is not running")
        return gw

    # ---- Hermes asks -----------------------------------------------------------------

    async def ask_approval(self, chat_id: str, session_key: str, command: str, description: str,
                           choices: list[str], smart_denied: bool = False) -> str:
        """Show an approval card; returns the message id to hand back to Hermes."""
        allowed = [c for c in choices if c in APPROVAL_CHOICES] or ["once", "deny"]
        card: dict[str, Any] = {
            "kind": "approval", "id": "c_" + uuid.uuid4().hex[:10], "status": "pending",
            "command": str(command or ""), "description": str(description or ""),
            "choices": allowed, "smart_denied": bool(smart_denied),
        }
        timeout = self._safe(self.resolvers.approval_timeout)
        if timeout:
            card["expires_at"] = _iso(self._clock() + timedelta(seconds=int(timeout)))
        text = "Wants to run: " + _one_line(command)
        seq = await self._gw().publish_card(chat_id, "approval", text, card)
        self._live[card["id"]] = _Live(seq, chat_id, "approval", session_key, card)
        return CARD_MESSAGE_PREFIX + card["id"]

    async def ask_question(self, chat_id: str, session_key: str, question: str,
                           choices: Optional[list], clarify_id: str, multi_select: bool = False) -> str:
        options = [str(c) for c in (choices or []) if str(c).strip()]
        card: dict[str, Any] = {
            "kind": "question", "id": "c_" + uuid.uuid4().hex[:10], "status": "pending",
            "question": str(question or ""), "choices": options,
            "multi_select": bool(multi_select and options),
        }
        text = "Asks: " + _one_line(question)
        seq = await self._gw().publish_card(chat_id, "question", text, card)
        self._live[card["id"]] = _Live(seq, chat_id, "question", session_key, card,
                                       clarify_id=clarify_id, choices=options)
        return CARD_MESSAGE_PREFIX + card["id"]

    async def ask_confirm(self, chat_id: str, session_key: str, title: str, message: str,
                          confirm_id: str) -> str:
        """A slash command (e.g. /new) asking to be confirmed: Approve / Always / Cancel."""
        card: dict[str, Any] = {
            "kind": "confirm", "id": "c_" + uuid.uuid4().hex[:10], "status": "pending",
            "title": _plain_title(title), "description": _confirm_detail(message),
            "choices": list(CONFIRM_CHOICES),
            "expires_at": _iso(self._clock() + timedelta(seconds=CONFIRM_TIMEOUT)),
        }
        seq = await self._gw().publish_card(chat_id, "confirm", card["title"], card)
        self._live[card["id"]] = _Live(seq, chat_id, "confirm", session_key, card, clarify_id=confirm_id)
        return CARD_MESSAGE_PREFIX + card["id"]

    # ---- the phone answers -----------------------------------------------------------

    async def respond(self, profile_id: str, data: dict) -> tuple[str, str]:
        """Returns (card id, its status afterwards). Raises PromptError for bad requests."""
        card_id = data.get("card_id")
        if not isinstance(card_id, str):
            raise PromptError("UNKNOWN_CARD", "No such card")
        live = self._live.get(card_id)
        if live is None or live.chat_id != profile_id:
            stored = self._stored_card(profile_id, card_id)
            if stored is None:
                raise PromptError("UNKNOWN_CARD", "No such card")
            return card_id, stored.get("status", "expired")  # answered, closed or from a past run
        if live.kind == "approval":
            return card_id, await self._answer_approval(live, data)
        if live.kind == "confirm":
            return card_id, await self._answer_confirm(live, data)
        return card_id, await self._answer_question(live, data)

    async def _answer_confirm(self, live: _Live, data: dict) -> str:
        choice = data.get("choice")
        if choice not in CONFIRM_CHOICES:
            raise PromptError("INVALID_ANSWER", "That choice isn't offered for this request")
        self._live.pop(live.card["id"], None)  # Hermes runs it once; a second tap must not
        try:
            ran, text = await self.resolvers.confirm(live.session_key, live.clarify_id or "", choice)
        except Exception:
            log.exception("Lekora: a Hermes confirmation failed")
            ran, text = False, None
        if not ran:
            await self._close(live, "expired")
            return "expired"
        await self._close(live, CONFIRM_STATUS[choice])
        if text and text.strip():
            await self._gw().publish_message(live.chat_id, text, role="system")  # e.g. "New session started"
        return CONFIRM_STATUS[choice]

    async def _answer_approval(self, live: _Live, data: dict) -> str:
        choice = data.get("choice")
        if choice not in live.card["choices"]:
            raise PromptError("INVALID_ANSWER", "That choice isn't offered for this request")
        reason = data.get("reason") if choice == "deny" else None
        reason = _one_line(reason, MAX_REASON) if isinstance(reason, str) and reason.strip() else None
        resolved = self._safe(lambda: self.resolvers.approve(live.session_key, choice, reason)) or 0
        if not resolved:
            await self._close(live, "expired")
            return "expired"
        extra = {"reason": reason} if reason else {}
        await self._close(live, APPROVAL_STATUS[choice], **extra)
        return APPROVAL_STATUS[choice]

    async def _answer_question(self, live: _Live, data: dict) -> str:
        answers, text = data.get("answers"), data.get("text")
        if isinstance(text, str) and text.strip():
            response = display = text.strip()[:MAX_ANSWER]
        elif isinstance(answers, list) and answers and all(a in live.choices for a in answers):
            if len(answers) > 1 and not live.card.get("multi_select"):
                raise PromptError("INVALID_ANSWER", "Choose one option")
            picked = list(dict.fromkeys(answers))  # no repeats, in the order tapped
            response = json.dumps(picked) if live.card.get("multi_select") else picked[0]
            display = ", ".join(picked)
        else:
            raise PromptError("INVALID_ANSWER", "Choose an option or type an answer")
        ok = self._safe(lambda: self.resolvers.answer(live.clarify_id or "", response))
        if not ok:
            await self._close(live, "expired")
            return "expired"
        await self._close(live, "answered", answer=display)
        return "answered"

    # ---- cards Hermes no longer waits on ---------------------------------------------

    async def approval_timed_out(self, card_id: str) -> bool:
        """Hermes edited the card after its timeout: nothing ran."""
        live = self._live.get(card_id)
        if live is None or live.kind != "approval":
            return False
        await self._close(live, "timed_out")
        return True

    async def question_retired(self, clarify_id: str) -> None:
        """Hermes ended a question without a button answer (timeout, reset, typed reply)."""
        for live in list(self._live.values()):
            if live.kind == "question" and live.clarify_id == clarify_id:
                await self._close(live, "closed")

    async def turn_ended(self, chat_id: str) -> None:
        """A turn in this chat is over: close the cards Hermes no longer waits on."""
        for live in list(self._live.values()):
            if live.chat_id == chat_id and not self._still_waiting(live):
                await self._close(live, "closed")

    async def user_message(self, chat_id: str, text: str) -> None:
        """A typed message: /approve or /deny may answer approvals, anything else questions.
        Hermes handles it a moment later; then the cards it answered are marked."""
        command = (text or "").strip().lower()
        typed_answer = command.startswith(("/approve", "/deny", "/always", "/cancel",
                                           "!approve", "!deny", "!always", "!cancel"))
        # Hermes also drops a waiting slash-command confirmation when any next message arrives.
        candidates = [live for live in self._live.values()
                      if live.chat_id == chat_id and (live.kind == "confirm"
                                                      or (live.kind == "approval") == typed_answer)]
        if not candidates:
            return

        async def recheck() -> None:
            await asyncio.sleep(self.recheck_delay)
            for live in candidates:
                if live.card["id"] in self._live and not self._still_waiting(live):
                    await self._close(live, "answered_in_chat")

        task = asyncio.get_running_loop().create_task(recheck())
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)

    def _still_waiting(self, live: _Live) -> bool:
        waiting = self._safe(lambda: self.resolvers.waiting(live.kind, live.session_key, live.clarify_id))
        return bool(waiting)  # unknown counts as not waiting

    async def expire_leftovers(self) -> int:
        """At startup: cards still pending from a previous run can't be answered any more."""
        gw = self._gw()
        count = 0
        for event in gw.store.pending_cards():
            card = dict(event.payload.get("card") or {}, status="expired")
            await gw.update_card(event.seq, card)
            count += 1
        return count

    # ---- helpers ---------------------------------------------------------------------

    async def _close(self, live: _Live, status: str, **extra: Any) -> None:
        self._live.pop(live.card["id"], None)
        live.card = dict(live.card, status=status, **extra)
        await self._gw().update_card(live.seq, live.card)

    def _stored_card(self, profile_id: str, card_id: str) -> Optional[dict]:
        for event in self._gw().store.events_for_profile(profile_id):
            card = event.payload.get("card")
            if isinstance(card, dict) and card.get("id") == card_id:
                return card
        return None

    @staticmethod
    def _safe(fn: Callable[[], Any]) -> Any:
        try:
            return fn()
        except Exception:
            log.exception("Lekora: a Hermes prompt call failed")
            return None

    def pending_count(self) -> int:
        return len(self._live)
