"""Voice mode (spec: docs/voice.md §2): replies arrive as voice notes in the agent's own Hermes
voice, streamed sentence by sentence while the reply is still being written.

As the text of a reply grows, each finished sentence is spoken with Hermes' own
``text_to_speech`` (whatever voice that agent uses: built in, a command provider or a plugin
one) and sent to the phones straight away (``voice.segment``), so they start playing at once.
When the reply is saved and every sentence is spoken, the parts are attached to the message
(``spoken``) and it shows as a voice note from then on, with its text as the transcript.
Turning voice mode off changes only the replies that come after.

Personality voice: the agent itself writes the way it talks (Hermes' per-chat instruction for
the turn, ``MessageEvent.channel_prompt``; see ``turn_instructions``), and exactly that text is
spoken. Nothing is rewritten behind the agent's back, so what you hear, what you read and what
the agent remembers are the same (owner, 2026-11-12: a hidden rewrite once made up a story the
agent knew nothing about).
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
    style: str                    # tts | personality
    instructions: str = ""
    spoken: int = 0
    pending: str = ""             # text waiting to be spoken with the next piece
    queue: asyncio.Queue = field(default_factory=asyncio.Queue)
    parts: list[dict] = field(default_factory=list)
    scripts: list[str] = field(default_factory=list)   # what was actually said, piece by piece
    seq: Optional[int] = None
    worker: Optional[asyncio.Task] = None
    problem: Optional[str] = None


# (profile, text) -> audio files, in order (blocking; Hermes' own text_to_speech)
Synthesize = Callable[[str, str], list[Path]]

MIN_TTS_PIECE = 40            # very short sentences are spoken with the next (less choppy)
MIN_PERSONALITY_PIECE = MIN_TTS_PIECE


class VoiceReplies:
    def __init__(self, gateway: Any, settings: Any, synthesize: Optional[Synthesize],
                 persona: Optional[Callable[[str, Optional[str]], str]] = None) -> None:
        # (profile, Hermes personality name or None for the agent's own) -> its text (blocking)
        self.persona = persona
        self.gateway = gateway
        self.settings = settings          # VoiceSettings
        self.synthesize = synthesize
        self._replies: dict[str, _Reply] = {}
        self._decided: dict[str, Optional[str]] = {}
        self._last_was_voice: dict[str, bool] = {}

    # ---- when is it on ---------------------------------------------------------------

    def user_message(self, profile_id: str, voice: bool) -> None:
        self._last_was_voice[profile_id] = voice

    def _choose(self, profile_id: str) -> Optional[dict]:
        """Voice-mode settings for a new reply, or None (a text reply)."""
        if self.synthesize is None or self.gateway.files is None:
            return None
        settings = self.settings.get_settings(profile_id)
        mode = settings.get("speak", "off")
        if not (mode == "always" or (mode == "voice_notes" and self._last_was_voice.get(profile_id))):
            return None
        if not self.settings.hermes_voice(profile_id).get("available"):
            return None
        return settings

    async def turn_instructions(self, profile_id: str) -> Optional[str]:
        """Personality voice: Hermes' per-chat instruction for the coming turn, so the agent
        writes its reply the way it talks (who's speaking + cadence). None otherwise. Only
        while personality voice is on for this chat; it stops when it's turned off."""
        settings = await asyncio.to_thread(self._choose, profile_id)
        if settings is None or settings.get("style") != "personality":
            return None
        from .voice_settings import voice_turn_instructions
        persona = ""
        source = settings.get("style_source", "hermes")
        if source == "preset" and self.persona is not None:
            # The agent already is its own Hermes self; a Hermes personality is described to it.
            try:
                persona = await asyncio.to_thread(self.persona, profile_id, settings.get("style_preset"))
            except Exception:
                log.warning("Lekora: couldn't read Hermes' %s personality", settings.get("style_preset"), exc_info=True)
        return voice_turn_instructions(settings, persona)

    async def begin(self, profile_id: str, key: str) -> Optional[str]:
        """Decides once, at the very start of a reply, whether it's a voice note; phones are
        told straight away so they show a voice note from the first word (never text first)."""
        if key in self._decided:
            return self._decided[key]
        self._decided[key] = None  # while deciding: a second update doesn't decide again
        settings = await asyncio.to_thread(self._choose, profile_id)
        if settings is None:
            return None
        style = "personality" if settings.get("style") == "personality" else "tts"
        instructions = ""
        reply = _Reply(profile_id, key, style, instructions)
        self._replies[key] = reply
        self._decided[key] = style
        if len(self._decided) > 500:
            for old in list(self._decided)[:250]:
                self._decided.pop(old, None)
        reply.worker = asyncio.create_task(self._speak_all(reply))
        await self.gateway.publish_voice_reply(profile_id, key, style)
        return style

    # ---- following replies -------------------------------------------------------------

    async def reply_text(self, profile_id: str, key: str, text: str, final: bool, seq: Optional[int] = None) -> None:
        """A reply's text so far (or saved, when ``final``)."""
        if not text.strip():
            return
        if key not in self._decided:
            await self.begin(profile_id, key)
        reply = self._replies.get(key)
        if reply is None:
            return
        sentences, reply.spoken = next_sentences(text, reply.spoken, final)
        least = MIN_PERSONALITY_PIECE if reply.style == "personality" else MIN_TTS_PIECE
        for sentence in sentences:
            reply.pending = f"{reply.pending} {sentence}".strip()
            if len(reply.pending) >= least:
                reply.queue.put_nowait(reply.pending)
                reply.pending = ""
        if final:
            if reply.pending:
                reply.queue.put_nowait(reply.pending)
                reply.pending = ""
            reply.seq = seq
            reply.queue.put_nowait(None)  # done once these are spoken

    async def _speak_all(self, reply: _Reply) -> None:
        index = 0
        while True:
            piece = await reply.queue.get()
            if piece is None:
                break
            if reply.problem:
                continue  # the voice can't be played here: nothing more to make
            script, paths = await self._speak(reply, piece)
            if paths:
                reply.scripts.append(script)
            for number, path in enumerate(paths):
                try:
                    part = await asyncio.to_thread(
                        self.gateway.files.add_agent_file, reply.profile_id, path,
                        f"Voice reply part {index + 1}{path.suffix or '.mp3'}")
                except Exception:
                    log.exception("Lekora: couldn't keep a voice reply part")
                    continue
                reply.parts.append(part)
                # The words go with the first audio part of each piece (what you hear).
                await self.gateway.publish_voice_segment(reply.profile_id, reply.key, index, part)
                index += 1
        self._replies.pop(reply.key, None)
        if reply.seq is not None:
            await self.gateway.attach_spoken(reply.seq, reply.parts, reply.style, reply.problem)

    async def _speak(self, reply: _Reply, piece: str) -> tuple[str, list[Path]]:
        """The words spoken (the reply's own) and their audio."""
        from .playable_audio import UnplayableAudio, playable
        script = piece  # exactly what the agent wrote (it wrote it to be spoken)
        for attempt in (1, 2):  # a provider hiccup gets one retry
            try:
                paths = [Path(p) for p in await asyncio.to_thread(self.synthesize, reply.profile_id, script)]
                return script, [await asyncio.to_thread(playable, p) for p in paths]
            except UnplayableAudio as exc:
                reply.problem = exc.reason
                log.warning("Lekora: %s", exc.reason)
                await self.gateway.publish_voice_reply(reply.profile_id, reply.key, reply.style, exc.reason)
                return script, []
            except Exception as exc:
                log.warning("Lekora: Hermes couldn't speak for %s (try %d): %s", reply.profile_id, attempt, exc)
        return script, []
