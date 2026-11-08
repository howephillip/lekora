"""Streaming replies to the phone (spec: docs/streaming.md).

Hermes streams a reply by sending its first words, then editing that message with
the growing text (full text so far, ending with a cursor like " ▉"). This module
turns those calls into Lekora's protocol:

- a send marked ``expect_edits`` opens a *live reply*: its text goes to the phone as
  ``chat.draft`` (not stored, not replayed);
- each edit updates the draft;
- an edit with ``finalize=True`` seals it: the text is saved as a normal
  ``chat.message`` (linked to the draft so the phone swaps it in place);
- a later edit of a saved message (Hermes correcting it) updates it in place;
- when the turn ends, any live reply that was never sealed is saved as-is, so what
  the phone showed is never lost.

Ordinary sends (not ``expect_edits``) are saved straight away, as before.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from typing import Any, Callable, Optional

DEFAULT_CURSOR = " ▉"


def strip_cursor(text: str, cursor: Optional[str]) -> str:
    for c in (cursor, DEFAULT_CURSOR, DEFAULT_CURSOR.strip()):
        if c and text.endswith(c):
            return text[: -len(c)].rstrip()
    return text


@dataclass
class _Live:
    chat_id: str
    text: str
    seq: Optional[int] = None  # set once sealed (saved)


class LiveReplies:
    def __init__(self, gateway: Callable[[], Any], cursor: Callable[[], Optional[str]] = lambda: DEFAULT_CURSOR):
        self._gateway = gateway
        self._cursor = cursor
        self._live: dict[str, _Live] = {}

    def _gw(self) -> Any:
        gw = self._gateway()
        if gw is None:
            raise RuntimeError("Lekora is not running")
        return gw

    async def send(self, chat_id: str, content: str, expect_edits: bool) -> str:
        """Returns the message id Hermes will use for later edits."""
        if not expect_edits:
            return str(await self._gw().publish_message(chat_id, content))
        draft_id = f"live-{uuid.uuid4().hex[:12]}"
        text = strip_cursor(content, self._cursor())
        self._live[draft_id] = _Live(chat_id, text)
        await self._gw().publish_draft(chat_id, draft_id, text)
        return draft_id

    async def edit(self, chat_id: str, message_id: str, content: str, finalize: bool) -> bool:
        text = strip_cursor(content, self._cursor())
        live = self._live.get(message_id)
        if live is not None:
            if live.seq is None:
                live.text = text
                if finalize:
                    await self._seal(message_id, live)
                else:
                    await self._gw().publish_draft(live.chat_id, message_id, text)
            elif text != live.text:  # a correction after it was saved
                live.text = text
                await self._gw().update_message(live.seq, text)
            return True
        if message_id.isdigit():  # an ordinary (already saved) message
            return await self._gw().update_message(int(message_id), text)
        return False

    async def turn_ended(self, chat_id: str) -> None:
        """Save live replies Hermes never sealed, then forget this chat's live replies."""
        for draft_id, live in list(self._live.items()):
            if live.chat_id != chat_id:
                continue
            if live.seq is None:
                await self._seal(draft_id, live)
            del self._live[draft_id]

    async def _seal(self, draft_id: str, live: _Live) -> None:
        if live.text.strip():
            live.seq = await self._gw().publish_message(live.chat_id, live.text, draft_id=draft_id)
        else:  # nothing worth keeping: tell phones to drop the empty bubble
            await self._gw().publish_draft(live.chat_id, draft_id, "")
            live.seq = -1

    @property
    def open_count(self) -> int:
        return len(self._live)
