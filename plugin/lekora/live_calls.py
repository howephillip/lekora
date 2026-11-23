"""Live voice engines for calls (docs/live-calls.md; owner, 2026-11-22): a real-time speech model holds the
conversation while the user's own Hermes agent does the real work.

- ``gpt-live``: OpenAI's GPT-Live over a WebSocket opened here (the key never leaves the instance). The
  phone's sound is relayed both ways; when GPT-Live hands work over (a delegation), the user's words go
  to the agent as a normal chat turn and its reply streams back for GPT-Live to say.
- ``fish-live``: Fish Audio's hosted Live 3 agent. Lekora creates (once) a Fish agent with an
  ``ask_agent`` client tool, then gives the phone a single-use LiveKit pass; the phone forwards each
  tool call here and the agent's reply goes back as the result.
- ``agent``: the call as before (the agent's own voice).

The chosen engine is kept per agent until changed. Nothing here imports Hermes: what needs it is passed in.
"""

from __future__ import annotations

import asyncio
import json
import logging
import re
import time
from typing import Any, AsyncIterator, Awaitable, Callable, Optional

log = logging.getLogger(__name__)

ENGINES = ("agent", "gpt-live", "fish-live")
ENGINE_NAMES = {"agent": "Your agent", "gpt-live": "GPT-Live", "fish-live": "Fish Live 3"}
FISH = "https://api.fish.audio"
FISH_TOOL = "ask_agent"
FISH_AGENT_VERSION = 1
COMMENTARY_CHARS = 1200       # GPT-Live takes up to 500 tokens per append
TURN_SECONDS = 110            # Fish client tools time out at 120 s

# Words said in a call reach the agent with this per-turn note (AGENTS.md rule 7, call exception): a live
# voice assistant speaks for it, so the reply must be short and speakable.
LIVE_NOTE = (
    "[This was said in a live voice call. A real-time voice assistant is talking with the user and "
    "passed this request to you; it will say your reply aloud in its own words. Reply in one to three "
    "short plain sentences with the answer itself: no markdown, lists, code or URLs. If the request "
    "needs longer work, say briefly that you're on it and hand it to a background task "
    "(delegate_task with background=true, if you have that tool); share the result when it comes back. "
    "Do not guess a result, and do not claim an action succeeded before it did.]"
)


class LiveError(Exception):
    def __init__(self, code: str, reason: str) -> None:
        super().__init__(reason)
        self.code = code
        self.reason = reason


def speakable_chunks(text: str, final: bool) -> tuple[list[str], int]:
    """Complete sentences of ``text`` (all of it when ``final``), split to fit one GPT-Live append, and how
    many characters they cover."""
    if final:
        end = len(text)
    else:
        found = [m.end() for m in re.finditer(r"[.!?…](\s|$)|\n", text)]
        end = found[-1] if found else 0
    body = text[:end].strip()
    chunks, current = [], ""
    for sentence in re.split(r"(?<=[.!?…])\s+|\n+", body):
        sentence = sentence.strip()
        if not sentence:
            continue
        while len(sentence) > COMMENTARY_CHARS:
            chunks.append(sentence[:COMMENTARY_CHARS])
            sentence = sentence[COMMENTARY_CHARS:]
        if current and len(current) + 1 + len(sentence) > COMMENTARY_CHARS:
            chunks.append(current)
            current = sentence
        else:
            current = f"{current} {sentence}".strip()
    if current:
        chunks.append(current)
    return chunks, end


class GptLiveSession:
    """One GPT-Live call, relayed for a phone (docs/live-calls.md)."""

    def __init__(self, connect: Callable[..., Awaitable[Any]], url: str, key: str, session: dict,
                 to_phone: Callable[[str, dict], Awaitable[None]],
                 agent_turn: Callable[[str], AsyncIterator[str]]) -> None:
        self._connect = connect
        self._url = url
        self._key = key
        self._session = session
        self._to_phone = to_phone
        self._agent_turn = agent_turn
        self._ws: Any = None
        self._reader: Optional[asyncio.Task] = None
        self._heard: list[str] = []          # what the user said since the last delegation
        self._tasks: set[asyncio.Task] = set()
        self.closed = False

    async def open(self) -> dict:
        self._ws = await self._connect(self._url, {"Authorization": f"Bearer {self._key}"})
        await self._ws.send(json.dumps({"type": "session.start", "event_id": "lekora_start", "session": self._session}))
        while True:
            event = json.loads(await asyncio.wait_for(self._ws.recv(), 15))
            if event.get("type") == "session.started":
                break
            if event.get("type") == "error":
                raise LiveError("LIVE_FAILED", (event.get("error") or {}).get("message") or "GPT-Live refused the call")
        self._reader = asyncio.create_task(self._read())
        return {"session_id": (event.get("session") or {}).get("id")}

    async def audio(self, data: str) -> None:
        if self._ws is not None and not self.closed:
            await self._ws.send(json.dumps({"type": "session.input_audio.append", "audio": data}))

    async def mute(self, muted: bool) -> None:
        if self._ws is not None and not self.closed:
            await self._ws.send(json.dumps({"type": "session.input_audio.mute" if muted else "session.input_audio.unmute"}))

    async def _read(self) -> None:
        try:
            async for raw in self._ws:
                event = json.loads(raw)
                kind = event.get("type")
                if kind == "session.output_audio.delta":
                    await self._to_phone("live.audio", {"data": event.get("delta") or ""})
                elif kind == "session.input_transcript.delta":
                    text = event.get("delta") or ""
                    self._heard.append(text)
                    await self._to_phone("live.event", {"kind": "transcript", "who": "user", "text": text})
                elif kind == "session.output_transcript.delta":
                    await self._to_phone("live.event", {"kind": "transcript", "who": "voice", "text": event.get("delta") or ""})
                elif kind == "session.delegation.created":
                    delegation = (event.get("delegation") or {}).get("id")
                    if delegation:
                        task = asyncio.create_task(self._delegate(delegation))
                        self._tasks.add(task)
                        task.add_done_callback(self._tasks.discard)
                elif kind == "error":
                    log.warning("Lekora: GPT-Live error: %s", event.get("error"))
                    await self._to_phone("live.event", {"kind": "error", "text": (event.get("error") or {}).get("message") or "GPT-Live error"})
                elif kind == "session.closed":
                    await self._to_phone("live.event", {"kind": "closed", "text": event.get("reason") or ""})
                    break
        except Exception as exc:  # the connection dropped
            if not self.closed:
                log.info("Lekora: GPT-Live connection ended: %s", exc)
                await self._to_phone("live.event", {"kind": "closed", "text": "connection lost"})
        finally:
            self.closed = True

    async def _delegate(self, delegation: str) -> None:
        """GPT-Live handed work over: the user's words since the last hand-over go to the agent; its reply
        is streamed back for GPT-Live to say (the delegation carries no text: docs say use the transcript)."""
        request = " ".join(" ".join(self._heard).split())
        self._heard = []
        if not request:
            return
        await self._to_phone("live.event", {"kind": "working"})
        try:
            async for chunk in self._agent_turn(request):
                if self.closed:
                    return
                await self._ws.send(json.dumps({"type": "session.commentary.append", "delegation_id": delegation,
                                                "content": chunk}))
        except Exception as exc:
            log.warning("Lekora: the agent's turn for GPT-Live failed: %s", exc)
            if not self.closed:
                await self._ws.send(json.dumps({"type": "session.commentary.append", "delegation_id": delegation,
                                                "content": "The agent couldn't answer that just now."}))
        finally:
            await self._to_phone("live.event", {"kind": "done"})

    async def close(self) -> None:
        if self.closed and self._ws is None:
            return
        self.closed = True
        for task in list(self._tasks):
            task.cancel()
        try:
            if self._ws is not None:
                await self._ws.send(json.dumps({"type": "session.close"}))
                await self._ws.close()
        except Exception:
            pass
        if self._reader is not None:
            self._reader.cancel()


class LiveCalls:
    """The engine setting per agent, and the live sessions."""

    def __init__(self, store: Any, profiles: Callable[[], list], agent_turn: Callable[[str, str], AsyncIterator[str]],
                 gpt_setup: Optional[Callable[[str, list], dict]] = None,
                 fish_key: Optional[Callable[[str], Optional[str]]] = None,
                 connect: Optional[Callable[..., Awaitable[Any]]] = None,
                 http: Optional[Callable[[str, str, Optional[dict], str], Any]] = None,
                 history: Callable[[str], list] = lambda p: [],
                 agent_name: Callable[[str], str] = lambda p: p) -> None:
        self._store = store
        self._profiles = profiles
        self._agent_turn = agent_turn       # (profile, request) -> the agent's reply in speakable pieces
        self._gpt_setup = gpt_setup         # (profile, history) -> {"url", "key", "session"}
        self._fish_key = fish_key
        self._connect = connect
        self._http = http                   # (method, url, body, key) -> parsed JSON
        self._history = history
        self._agent_name = agent_name
        self._sessions: dict[str, Any] = {}

    def _agent(self, profile_id: Any) -> str:
        if not isinstance(profile_id, str) or profile_id not in {p["profile_id"] for p in self._profiles()}:
            raise LiveError("UNKNOWN_PROFILE", "Unknown agent")
        return profile_id

    # ---- the setting ---------------------------------------------------------

    def engines(self, profile_id: Any) -> dict:
        profile_id = self._agent(profile_id)
        engine = self._store.get_app_setting(profile_id, "call_engine") or "agent"
        listed = [{"id": "agent", "name": ENGINE_NAMES["agent"], "available": True}]
        gpt = self._gpt_status(profile_id)
        listed.append({"id": "gpt-live", "name": ENGINE_NAMES["gpt-live"], **gpt})
        fish = bool(self._fish_key and self._fish_key(profile_id))
        listed.append({"id": "fish-live", "name": ENGINE_NAMES["fish-live"], "available": fish,
                       **({} if fish else {"reason": "Needs a Fish Audio API key on the Hermes instance (FISH_AUDIO)"})})
        return {"engine": engine if engine in ENGINES else "agent", "engines": listed}

    def _gpt_status(self, profile_id: str) -> dict:
        if self._gpt_setup is None:
            return {"available": False, "reason": "This Hermes has no GPT-Live support"}
        try:
            self._gpt_setup(profile_id, [])
            return {"available": True}
        except LiveError as exc:
            return {"available": False, "reason": exc.reason}

    def set_engine(self, profile_id: Any, engine: Any) -> dict:
        profile_id = self._agent(profile_id)
        if engine not in ENGINES:
            raise LiveError("INVALID_REQUEST", "Unknown call engine")
        self._store.set_app_setting(profile_id, "call_engine", engine)
        return self.engines(profile_id)

    # ---- calls -----------------------------------------------------------------

    async def start(self, profile_id: Any, engine: Any, to_phone: Callable[[str, dict], Awaitable[None]]) -> dict:
        profile_id = self._agent(profile_id)
        await self.stop(profile_id)
        if engine == "gpt-live":
            if self._gpt_setup is None or self._connect is None:
                raise LiveError("UNAVAILABLE", "GPT-Live isn't available on this Hermes instance")
            setup = await asyncio.to_thread(self._gpt_setup, profile_id, self._history(profile_id))
            session = GptLiveSession(self._connect, setup["url"], setup["key"], setup["session"], to_phone,
                                     lambda request: self._agent_turn(profile_id, request))
            try:
                opened = await session.open()
            except LiveError:
                raise
            except Exception as exc:
                raise LiveError("LIVE_FAILED", f"GPT-Live couldn't start: {exc}")
            self._sessions[profile_id] = session
            log.info("Lekora: GPT-Live call started for %s", profile_id)
            return {"engine": engine, **opened}
        if engine == "fish-live":
            key = self._fish_key(profile_id) if self._fish_key else None
            if not key or self._http is None:
                raise LiveError("UNAVAILABLE", "Fish Live 3 needs a Fish Audio API key on the Hermes instance")
            agent_id = await self._fish_agent(key)
            name = self._agent_name(profile_id)
            got = await asyncio.to_thread(self._http, "POST", f"{FISH}/v1/agent/sessions", {
                "agent_id": agent_id, "end_user_id": profile_id,
                "overrides": {"system_prompt": fish_prompt(name)}}, key)
            if not isinstance(got, dict) or not got.get("token") or not got.get("livekit_url"):
                raise LiveError("LIVE_FAILED", "Fish didn't start the call")
            self._sessions[profile_id] = {"fish": got.get("session_id"), "key": key}
            log.info("Lekora: Fish Live 3 call started for %s", profile_id)
            return {"engine": engine, "session_id": got.get("session_id"), "livekit_url": got["livekit_url"],
                    "token": got["token"]}
        raise LiveError("INVALID_REQUEST", "Unknown call engine")

    async def audio(self, profile_id: str, data: Any) -> None:
        session = self._sessions.get(profile_id)
        if isinstance(session, GptLiveSession) and isinstance(data, str):
            await session.audio(data)

    async def mute(self, profile_id: str, muted: bool) -> None:
        session = self._sessions.get(profile_id)
        if isinstance(session, GptLiveSession):
            await session.mute(bool(muted))

    async def ask(self, profile_id: Any, text: Any) -> dict:
        """Fish's ask_agent tool, forwarded by the phone: the agent's whole reply (within the tool's time)."""
        profile_id = self._agent(profile_id)
        request = " ".join(str(text or "").split())
        if not request:
            raise LiveError("INVALID_REQUEST", "Ask what?")
        parts: list[str] = []

        async def collect() -> None:
            async for chunk in self._agent_turn(profile_id, request):
                parts.append(chunk)
        try:
            await asyncio.wait_for(collect(), TURN_SECONDS)
        except asyncio.TimeoutError:
            parts.append("I'm still working on that; the answer will be in our chat.")
        return {"text": " ".join(parts).strip() or "I don't have an answer for that."}

    async def stop(self, profile_id: str) -> dict:
        session = self._sessions.pop(profile_id, None)
        if isinstance(session, GptLiveSession):
            await session.close()
        elif isinstance(session, dict) and session.get("fish") and self._http is not None:
            try:
                await asyncio.to_thread(self._http, "POST", f"{FISH}/v1/agent/sessions/{session['fish']}/end", None,
                                        session["key"])
            except Exception:
                log.debug("Lekora: ending the Fish session failed", exc_info=True)
        return {"stopped": session is not None}

    async def stop_all(self) -> None:
        for profile_id in list(self._sessions):
            await self.stop(profile_id)

    async def _fish_agent(self, key: str) -> str:
        """Lekora's Fish agent (Live 3, with the ask_agent tool), made and published once."""
        import hashlib
        slot = "fish_agent:" + hashlib.sha256(key.encode()).hexdigest()[:12]  # one per Fish account
        saved = self._store.get_app_setting("*", slot) or {}
        if isinstance(saved, dict) and saved.get("agent_id") and saved.get("version") == FISH_AGENT_VERSION:
            return saved["agent_id"]
        tool = await asyncio.to_thread(self._http, "POST", f"{FISH}/v1/agent/tools", {
            "tool_type": "client", "name": FISH_TOOL,
            "description": ("Ask the user's own AI agent, which has their tools, files, memory and accounts. "
                            "Use it for anything beyond small talk: questions, facts, plans, actions."),
            "parameters": {"type": "object", "properties": {"request": {
                "type": "string", "description": "What the user wants, in their own words, with any details they gave."}},
                "required": ["request"], "additionalProperties": False},
            "parameter_mode": "strict", "expects_response": True, "timeout_seconds": 120}, key)
        tool_id = _id(tool)
        agent = await asyncio.to_thread(self._http, "POST", f"{FISH}/v1/agent/agents", {
            "name": "Lekora", "description": "Live calls with the user's Hermes agents (made by Lekora)",
            "config": {"prompt": {"system_prompt": fish_prompt("your agent"), "first_message_mode": "off"},
                       "voice": {"engine": "live3", "voice_id": "clara"},
                       "tools": {"tool_ids": [tool_id]},
                       "conversation": {"max_duration_seconds": 3600}}}, key)
        agent_id = _id(agent)
        if not tool_id or not agent_id:
            raise LiveError("LIVE_FAILED", "Fish didn't create Lekora's voice agent")
        await asyncio.to_thread(self._http, "POST", f"{FISH}/v1/agent/agents/{agent_id}/publish",
                                {"version_title": "Lekora"}, key)
        self._store.set_app_setting("*", slot, {"agent_id": agent_id, "tool_id": tool_id,
                                                         "version": FISH_AGENT_VERSION})
        log.info("Lekora: made its Fish voice agent %s", agent_id)
        return agent_id


def _id(got: Any) -> Optional[str]:
    if not isinstance(got, dict):
        return None
    for key in ("id", "agent_id", "tool_id", "_id"):
        if got.get(key):
            return str(got[key])
    data = got.get("data") if isinstance(got.get("data"), dict) else None
    return _id(data) if data else None


def fish_prompt(name: str) -> str:
    return (f"You are the voice of {name}, the user's own AI agent, on a live phone-style call. Keep replies "
            "short and natural, one or two sentences. For anything beyond greetings and small talk (questions, "
            f"facts, plans, the user's data, actions) call the {FISH_TOOL} tool with the user's request in their "
            "words, say a brief 'one moment' while it works, then tell them the answer in your own words. Never "
            "make up an answer or claim something was done unless the tool said so.")


async def turn_pieces(updates: "asyncio.Queue[tuple[str, bool]]", timeout: float = 180) -> AsyncIterator[str]:
    """Turns an agent reply's updates (full text so far, final) into speakable pieces as sentences complete."""
    sent = 0
    deadline = time.monotonic() + timeout
    while True:
        text, final = await asyncio.wait_for(updates.get(), max(deadline - time.monotonic(), 0.1))
        if len(text) < sent:
            sent = 0 if not final else len(text)
        chunks, end = speakable_chunks(text[sent:], final)
        for chunk in chunks:
            yield chunk
        sent += end
        if final:
            return
