"""Voice mode (spec: docs/voice.md §2): replies arrive as voice notes in the agent's own Hermes
voice, streamed sentence by sentence while the reply is still being written.

As the text of a reply grows, each finished sentence is spoken with Hermes' own
``text_to_speech`` (whatever voice that agent uses: built in, a command provider or a plugin
one) and sent to the phones straight away (``voice.segment``), so they start playing at once.
When the reply is saved and every sentence is spoken, the parts are attached to the message
(``spoken``) and it shows as a voice note from then on, with its text as the transcript.
Turning voice mode off changes only the replies that come after.
"""

from __future__ import annotations

import asyncio
import logging
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Optional

log = logging.getLogger(__name__)

_CODE = re.compile(r"```[\s\S]*?(```|$)")
_LINK = re.compile(r"!?\[([^\]]*)\]\([^)]*\)")
_URL = re.compile(r"https?://\S+")
_LIST = re.compile(r"(?m)^\s{0,3}(#{1,6}|>|[-*+]|\d+\.)\s+")
_MARKS = re.compile(r"[*_`~|]")


def spoken_text(markdown: str) -> str:
    """What to say for a piece of Markdown (same rules as the app's iPhone voice)."""
    text = _CODE.sub(" ", markdown)
    text = _LINK.sub(r"\1", text)
    text = _URL.sub("link", text)
    text = _LIST.sub("", text)
    text = _MARKS.sub("", text)
    return " ".join(text.split())


def next_sentences(text: str, after: int, final: bool) -> tuple[list[str], int]:
    """Finished sentences of ``text`` after the first ``after`` characters (all the rest when
    ``final``), and how far that reaches. Open code blocks aren't split."""
    out: list[str] = []
    start = index = after
    in_code = text[:after].count("```") % 2 == 1
    while index < len(text):
        if text.startswith("```", index):
            in_code = not in_code
            index += 3
            continue
        char = text[index]
        following = text[index + 1] if index + 1 < len(text) else ""
        if not in_code and ((char in ".!?…" and following.isspace()) or char == "\n"):
            piece = spoken_text(text[start:index + 1])
            if piece:
                out.append(piece)
            start = index + 1
        index += 1
    if final and start < len(text):
        piece = spoken_text(text[start:])
        if piece:
            out.append(piece)
        start = len(text)
    return out, start


@dataclass
class _Reply:
    profile_id: str
    key: str                      # the phone's id for the message: draft id, or "seq-N"
    spoken: int = 0
    queue: asyncio.Queue = field(default_factory=asyncio.Queue)
    parts: list[dict] = field(default_factory=list)
    seq: Optional[int] = None
    worker: Optional[asyncio.Task] = None
    sentences: int = 0


# (profile, sentence) -> list of audio files (blocking; Hermes' own text_to_speech)
Synthesize = Callable[[str, str], list[Path]]


class VoiceReplies:
    def __init__(self, gateway: Any, settings: Any, synthesize: Optional[Synthesize]) -> None:
        self.gateway = gateway
        self.settings = settings          # VoiceSettings
        self.synthesize = synthesize
        self._replies: dict[str, _Reply] = {}
        self._last_was_voice: dict[str, bool] = {}

    # ---- when is it on ---------------------------------------------------------------

    def user_message(self, profile_id: str, voice: bool) -> None:
        self._last_was_voice[profile_id] = voice

    def _wanted(self, profile_id: str) -> bool:
        if self.synthesize is None or self.gateway.files is None:
            return False
        mode = (self.settings.store.get_app_setting(profile_id, "voice") or {}).get("speak", "off")
        if mode == "always" or (mode == "voice_notes" and self._last_was_voice.get(profile_id)):
            return bool(self.settings.hermes_voice(profile_id).get("available"))
        return False

    # ---- following replies -------------------------------------------------------------

    async def reply_text(self, profile_id: str, key: str, text: str, final: bool, seq: Optional[int] = None) -> None:
        """A reply's text so far (or saved, when ``final``)."""
        reply = self._replies.get(key)
        if reply is None:
            if not text.strip() or not await asyncio.to_thread(self._wanted, profile_id):
                return
            reply = _Reply(profile_id, key)
            self._replies[key] = reply
            reply.worker = asyncio.create_task(self._speak_all(reply))
        sentences, reply.spoken = next_sentences(text, reply.spoken, final)
        for sentence in sentences:
            reply.sentences += 1
            reply.queue.put_nowait(sentence)
        if final:
            reply.seq = seq
            reply.queue.put_nowait(None)  # done once these are spoken

    async def _speak_all(self, reply: _Reply) -> None:
        index = 0
        while True:
            sentence = await reply.queue.get()
            if sentence is None:
                break
            for path in await self._speak(reply.profile_id, sentence):
                try:
                    part = await asyncio.to_thread(
                        self.gateway.files.add_agent_file, reply.profile_id, path,
                        f"Voice reply part {index + 1}{path.suffix or '.mp3'}")
                except Exception:
                    log.exception("Lekora: couldn't keep a voice reply part")
                    continue
                reply.parts.append(part)
                await self.gateway.publish_voice_segment(reply.profile_id, reply.key, index, part)
                index += 1
        self._replies.pop(reply.key, None)
        if reply.seq is not None and reply.parts:
            await self.gateway.attach_spoken(reply.seq, reply.parts)

    async def _speak(self, profile_id: str, sentence: str) -> list[Path]:
        for attempt in (1, 2):  # a provider hiccup gets one retry
            try:
                return [Path(p) for p in await asyncio.to_thread(self.synthesize, profile_id, sentence)]
            except Exception as exc:
                log.warning("Lekora: Hermes couldn't speak a sentence for %s (try %d): %s", profile_id, attempt, exc)
        return []
