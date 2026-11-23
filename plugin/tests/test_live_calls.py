"""Live voice engines for calls (docs/live-calls.md): GPT-Live relayed through the instance, Fish Live 3
through a Fish agent with an ask_agent tool, the engine kept per agent."""

import asyncio
import json

import pytest

from lekora.gateway import Gateway
from lekora.live_calls import FISH, LIVE_NOTE, GptLiveSession, LiveCalls, LiveError, speakable_chunks
from tests.test_gateway import PROFILES, env, open_ws, recv
from tests.test_history import drain


class FakeOpenAI:
    """GPT-Live's WebSocket, as the docs describe it."""

    def __init__(self):
        self.sent, self.inbox, self.closed = [], asyncio.Queue(), False

    async def send(self, raw):
        event = json.loads(raw)
        self.sent.append(event)
        if event["type"] == "session.start":
            await self.inbox.put({"type": "session.started", "session": {"id": "live_1"}})

    async def recv(self):
        return json.dumps(await self.inbox.get())

    def __aiter__(self):
        return self

    async def __anext__(self):
        event = await self.inbox.get()
        if event is None:
            raise StopAsyncIteration
        return json.dumps(event)

    async def close(self):
        self.closed = True
        await self.inbox.put(None)


async def until(check, seconds=3):
    for _ in range(int(seconds / 0.02)):
        if check():
            return True
        await asyncio.sleep(0.02)
    return False


def test_replies_become_speakable_pieces():
    assert speakable_chunks("First sentence. Second one", False) == (["First sentence."], 16)
    assert speakable_chunks("First sentence. Second one", True) == (["First sentence. Second one"], 26)
    long = "word " * 400
    chunks, _ = speakable_chunks(long + ".", True)
    assert all(len(c) <= 1200 for c in chunks) and len(chunks) >= 2, "fits GPT-Live's 500-token appends"


async def test_gpt_live_relays_sound_and_hands_real_work_to_the_agent():
    ws = FakeOpenAI()
    to_phone, asked = [], []

    async def phone(kind, data):
        to_phone.append((kind, data))

    async def agent_turn(request):
        asked.append(request)
        yield "There's one meeting at three."
        yield "It's with Ada."

    async def connect(url, headers):
        assert url == "wss://api.openai.com/v1/live/sessions" and headers["Authorization"] == "Bearer sk-test"
        return ws

    session = GptLiveSession(connect, "wss://api.openai.com/v1/live/sessions", "sk-test",
                             {"model": "gpt-live-1", "delegation": {"type": "client"}}, phone, agent_turn)
    opened = await session.open()
    assert opened == {"session_id": "live_1"} and ws.sent[0]["type"] == "session.start"
    assert ws.sent[0]["session"]["delegation"] == {"type": "client"}
    await session.audio("AAAA")
    assert ws.sent[-1] == {"type": "session.input_audio.append", "audio": "AAAA"}
    await ws.inbox.put({"type": "session.output_audio.delta", "delta": "BBBB"})
    await ws.inbox.put({"type": "session.input_transcript.delta", "delta": "what's on"})
    await ws.inbox.put({"type": "session.input_transcript.delta", "delta": "my calendar today"})
    await ws.inbox.put({"type": "session.delegation.created", "delegation": {"id": "del_1", "target": "client"}})
    assert await until(lambda: sum(1 for e in ws.sent if e["type"] == "session.commentary.append") == 2)
    assert asked == ["what's on my calendar today"], "the user's words since the last hand-over"
    commentary = [e for e in ws.sent if e["type"] == "session.commentary.append"]
    assert [c["content"] for c in commentary] == ["There's one meeting at three.", "It's with Ada."]
    assert all(c["delegation_id"] == "del_1" for c in commentary)
    assert ("live.audio", {"data": "BBBB"}) in to_phone
    assert await until(lambda: ("live.event", {"kind": "done"}) in to_phone)
    await session.close()
    assert ws.closed and any(e["type"] == "session.close" for e in ws.sent)


class Settings:
    def __init__(self):
        self.values = {}

    def get_app_setting(self, profile, key):
        return self.values.get((profile, key))

    def set_app_setting(self, profile, key, value):
        self.values[(profile, key)] = value


async def test_the_engine_is_kept_per_agent_and_says_what_it_needs():
    def no_key(profile, history):
        raise LiveError("NO_KEY", "GPT-Live needs an OpenAI API key")
    live = LiveCalls(Settings(), lambda: PROFILES, None, gpt_setup=no_key, fish_key=lambda profile: "fk")
    got = live.engines("coder")
    assert got["engine"] == "agent"
    engines = {e["id"]: e for e in got["engines"]}
    assert engines["gpt-live"]["available"] is False and "OpenAI" in engines["gpt-live"]["reason"]
    assert engines["fish-live"]["available"] is True
    assert live.set_engine("coder", "fish-live")["engine"] == "fish-live"
    assert live.engines("coder")["engine"] == "fish-live", "kept until changed"
    assert live.engines("assistant")["engine"] == "agent", "per agent"
    with pytest.raises(LiveError):
        live.set_engine("coder", "nope")


async def test_fish_live_makes_its_agent_once_and_answers_tool_calls_with_the_agent():
    calls = []

    def http(method, url, body, key):
        calls.append((method, url.replace(FISH, ""), body))
        assert key == "fk"
        if url.endswith("/v1/agent/tools"):
            return {"id": "tool_1"}
        if url.endswith("/v1/agent/agents"):
            return {"id": "agent_1"}
        if url.endswith("/v1/agent/sessions"):
            return {"session_id": "s1", "livekit_url": "wss://x.livekit.cloud", "token": "tok"}
        return {}

    async def agent_turn(profile, request):
        assert profile == "coder" and request == "book ramen for two"
        yield "Booked for seven."

    store = Settings()
    live = LiveCalls(store, lambda: PROFILES, agent_turn, fish_key=lambda profile: "fk", http=http,
                     agent_name=lambda p: "Coder")

    async def phone(kind, data):
        pass
    got = await live.start("coder", "fish-live", phone)
    assert got == {"engine": "fish-live", "session_id": "s1", "livekit_url": "wss://x.livekit.cloud", "token": "tok"}
    tool = next(b for m, u, b in calls if u == "/v1/agent/tools")
    assert tool["name"] == "ask_agent" and tool["tool_type"] == "client" and tool["expects_response"] is True
    agent = next(b for m, u, b in calls if u == "/v1/agent/agents")
    assert agent["config"]["voice"]["engine"] == "live3" and agent["config"]["tools"]["tool_ids"] == ["tool_1"]
    assert ("POST", "/v1/agent/agents/agent_1/publish", {"version_title": "Lekora"}) in calls
    session = next(b for m, u, b in calls if u == "/v1/agent/sessions")
    assert "Coder" in session["overrides"]["system_prompt"] and "ask_agent" in session["overrides"]["system_prompt"]
    assert (await live.ask("coder", "book ramen for two")) == {"text": "Booked for seven."}
    await live.stop("coder")
    assert ("POST", "/v1/agent/sessions/s1/end", None) in calls
    calls.clear()
    await live.start("coder", "fish-live", phone)
    assert not any(u == "/v1/agent/agents" for m, u, b in calls), "the Fish agent is made once"


@pytest.fixture
async def live_gw(store):
    holder = {}

    async def dispatch(profile_id, text, message_id, **extra):
        holder["extra"] = extra
        g = holder["gw"]
        await g.publish_draft(profile_id, "d1", "Your next meeting is at three.")
        await g.publish_draft(profile_id, "d1", "Your next meeting is at three. It's with")
        await g.publish_message(profile_id, "Your next meeting is at three. It's with Ada.", draft_id="d1")

    g = Gateway(store, dispatch, lambda: PROFILES, endpoints=lambda p: [], host="127.0.0.1", auth_timeout=0.4)
    holder["gw"] = g
    g.holder = holder
    await g.start()
    yield g
    await g.stop()


async def test_words_said_in_a_live_call_are_a_chat_turn_with_the_call_note(live_gw, store):
    pieces = [p async for p in live_gw.live_agent_turn("coder", "when's my next meeting")]
    assert pieces == ["Your next meeting is at three.", "It's with Ada."], "spoken as sentences complete"
    assert live_gw.holder["extra"]["instructions"] == LIVE_NOTE, "the call note (rule 7 call exception)"
    texts = [(e.payload["role"], e.payload["text"]) for e in store.recent_messages(10) if e.profile_id == "coder"]
    assert ("user", "when's my next meeting") in texts, "the call is in the chat"
    assert live_gw.reply_listeners["coder"] == [], "nothing left listening"


async def test_the_phone_picks_an_engine_and_a_live_call_ends_with_the_phone(live_gw, store):
    ws_events = FakeOpenAI()

    async def connect(url, headers):
        return ws_events
    live_gw.live = LiveCalls(store, lambda: PROFILES, live_gw.live_agent_turn,
                             gpt_setup=lambda p, h: {"url": "wss://o/v1/live/sessions", "key": "k", "session": {}},
                             connect=connect)
    device_id, tok = store.register_device("iPhone")
    from tests.test_history import hello_rev
    ws = await hello_rev(live_gw, store, device_id, tok, since_rev=store.current_rev())
    await recv(ws)
    await ws.send(env(store, "live.engine.set", {"engine": "gpt-live"}, profile_id="coder", msg_id="e1"))
    got = [m for m in await drain(ws) if m.get("id") == "e1"][0]
    assert got["data"]["engine"] == "gpt-live"
    await ws.send(env(store, "live.start", {"engine": "gpt-live"}, profile_id="coder", msg_id="s1"))
    got = [m for m in await drain(ws) if m.get("id") == "s1"][0]
    assert got["type"] == "live.start.result" and got["data"]["session_id"] == "live_1"
    await ws.send(env(store, "live.audio", {"data": "CCCC"}, profile_id="coder"))
    assert await until(lambda: {"type": "session.input_audio.append", "audio": "CCCC"} in ws_events.sent)
    await ws_events.inbox.put({"type": "session.output_audio.delta", "delta": "DDDD"})
    heard = [m for m in await drain(ws) if m.get("type") == "live.audio"]
    assert heard and heard[0]["data"]["data"] == "DDDD", "its voice reaches the phone"
    await ws.close()
    assert await until(lambda: ws_events.closed), "the phone went away: the call ends"
