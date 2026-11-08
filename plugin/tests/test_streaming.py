from dataclasses import dataclass
from types import SimpleNamespace

import pytest

from lekora import hermes_streaming
from lekora.hermes_streaming import STREAMING_MARK, LekoraOnlyStreaming
from lekora.streaming import LiveReplies, strip_cursor


class RecordingGateway:
    """Records what LiveReplies asks the gateway to publish."""

    def __init__(self):
        self.calls = []
        self.roles = []
        self._seq = 0

    async def publish_message(self, profile_id, text, role="assistant", draft_id=None):
        self._seq += 1
        self.calls.append(("message", profile_id, text, draft_id, self._seq))
        self.roles.append(role)
        return self._seq

    async def publish_draft(self, profile_id, draft_id, text):
        self.calls.append(("draft", profile_id, text, draft_id))

    async def update_message(self, seq, text):
        self.calls.append(("update", seq, text))
        return True


@pytest.fixture
def gw():
    return RecordingGateway()


@pytest.fixture
def live(gw):
    return LiveReplies(lambda: gw)


def kinds(gw):
    return [c[0] for c in gw.calls]


# ---- the streaming flow Hermes drives ------------------------------------------

async def test_stream_then_seal(live, gw):
    mid = await live.send("bruce", "Hello ▉", expect_edits=True)
    assert mid.startswith("live-")
    assert await live.edit("bruce", mid, "Hello there ▉", finalize=False)
    assert await live.edit("bruce", mid, "Hello there, friend.", finalize=True)
    assert gw.calls == [
        ("draft", "bruce", "Hello", mid),
        ("draft", "bruce", "Hello there", mid),
        ("message", "bruce", "Hello there, friend.", mid, 1),   # saved, linked to the draft
    ]


async def test_correction_after_sealing_updates_the_saved_message(live, gw):
    mid = await live.send("bruce", "Draft ▉", expect_edits=True)
    await live.edit("bruce", mid, "Final", finalize=True)
    await live.edit("bruce", mid, "Final", finalize=True)          # unchanged: nothing to do
    await live.edit("bruce", mid, "Final, corrected", finalize=True)
    assert kinds(gw) == ["draft", "message", "update"]
    assert gw.calls[-1] == ("update", 1, "Final, corrected")


async def test_each_segment_is_its_own_message(live, gw):
    # Hermes seals a message at each tool boundary and starts a new one after.
    a = await live.send("default", "Let me check ▉", expect_edits=True)
    await live.edit("default", a, "Let me check.", finalize=True)
    b = await live.send("default", "Found it ▉", expect_edits=True)
    await live.edit("default", b, "Found it: 42.", finalize=True)
    saved = [c for c in gw.calls if c[0] == "message"]
    assert [(c[2], c[3]) for c in saved] == [("Let me check.", a), ("Found it: 42.", b)]


async def test_unsealed_reply_is_saved_when_the_turn_ends(live, gw):
    mid = await live.send("bruce", "Partial answer ▉", expect_edits=True)
    await live.turn_ended("bruce")
    assert gw.calls[-1] == ("message", "bruce", "Partial answer", mid, 1)
    assert live.open_count == 0


async def test_turn_end_only_touches_that_agents_replies(live, gw):
    a = await live.send("bruce", "B ▉", expect_edits=True)
    await live.send("work", "W ▉", expect_edits=True)
    await live.turn_ended("bruce")
    assert [c for c in gw.calls if c[0] == "message"] == [("message", "bruce", "B", a, 1)]
    assert live.open_count == 1


async def test_empty_live_reply_is_dropped_not_saved(live, gw):
    mid = await live.send("bruce", " ▉", expect_edits=True)
    await live.edit("bruce", mid, "", finalize=True)
    assert gw.calls[-1] == ("draft", "bruce", "", mid)   # phone removes the bubble
    assert "message" not in kinds(gw)


async def test_ordinary_sends_are_saved_and_can_be_edited(live, gw):
    mid = await live.send("default", "Still working on it…", expect_edits=False)
    assert mid == "1" and gw.calls == [("message", "default", "Still working on it…", None, 1)]
    assert await live.edit("default", mid, "Done.", finalize=False)
    assert gw.calls[-1] == ("update", 1, "Done.")


async def test_unknown_message_edit_fails(live):
    assert await live.edit("default", "not-ours", "x", finalize=True) is False


async def test_not_running_raises(gw):
    live = LiveReplies(lambda: None)
    with pytest.raises(RuntimeError):
        await live.send("default", "x", expect_edits=True)


@pytest.mark.parametrize("raw,cursor,expected", [
    ("Hello ▉", " ▉", "Hello"),
    ("Hello▉", None, "Hello"),
    ("Hello |", " |", "Hello"),           # a user-configured cursor
    ("Hello", " ▉", "Hello"),
])
def test_strip_cursor(raw, cursor, expected):
    assert strip_cursor(raw, cursor) == expected


# ---- streaming switched on for Lekora only -----------------------------------

@dataclass
class FakeStreamingConfig:
    """Same rule as Hermes' gateway.config.StreamingConfig (config.py:509-515)."""
    enabled: bool = False
    transport: str = "auto"
    cursor: str = " ▉"

    @property
    def globally_enabled(self):
        return bool(self.enabled) and self.transport != "off"

    def enabled_for(self, platform_override):
        return self.globally_enabled and (platform_override is None or bool(platform_override))


def runner(streaming):
    return SimpleNamespace(config=SimpleNamespace(streaming=streaming))


def test_streams_for_lekora_only_and_others_keep_their_setting():
    r = runner(FakeStreamingConfig(enabled=False))
    assert hermes_streaming.install(r)
    s = r.config.streaming
    assert s.enabled_for(STREAMING_MARK) is True      # Lekora
    assert s.enabled_for(None) is False               # Telegram etc. following the global switch
    assert s.enabled_for(True) is False               # a per-platform True can't override global off
    assert s.globally_enabled is False                # Hermes' other check (streaming TTS) unchanged
    assert s.cursor == " ▉" and s.transport == "auto"


def test_user_who_enabled_streaming_globally_is_unaffected():
    r = runner(FakeStreamingConfig(enabled=True))
    hermes_streaming.install(r)
    assert r.config.streaming.enabled_for(None) is True
    assert r.config.streaming.enabled_for(False) is False   # their per-platform "off" still works


def test_transport_off_is_respected_for_lekora_too():
    r = runner(FakeStreamingConfig(enabled=False, transport="off"))
    hermes_streaming.install(r)
    assert r.config.streaming.enabled_for(STREAMING_MARK) is False


def test_install_is_idempotent_and_writes_through():
    original = FakeStreamingConfig()
    r = runner(original)
    hermes_streaming.install(r)
    wrapped = r.config.streaming
    hermes_streaming.install(r)
    assert r.config.streaming is wrapped                  # not wrapped twice
    wrapped.edit_interval = 0.5
    assert original.edit_interval == 0.5                  # settings still reach Hermes' object


@pytest.mark.parametrize("bad", [None, SimpleNamespace(config=None),
                                 runner(SimpleNamespace(enabled=True))])  # no enabled_for
def test_falls_back_to_whole_replies(bad, caplog, monkeypatch):
    monkeypatch.setattr(hermes_streaming, "_last_problem", None)  # each problem is logged once
    assert hermes_streaming.install(bad) is False
    assert "won't stream" in caplog.text


def test_cursor_of():
    assert hermes_streaming.cursor_of(runner(LekoraOnlyStreaming(FakeStreamingConfig(cursor=" |")))) == " |"
    assert hermes_streaming.cursor_of(None) is None


# ---- Hermes' own notices ------------------------------------------------------------

from lekora import notices


@pytest.mark.parametrize("text,kind", [
    ("⚠️ Hermes is restarting — your current task will be interrupted. Send any message after "
     "the restart and I'll try to resume where you left off.", notices.NOTICE),
    ("♻️ Gateway online — Hermes is back and ready.", notices.NOTICE),
    ("✅ Background task finished — `cd /home/phillip/.hermes/cache/scratch && hermes -p carl -z "
     "\"$(cat carl-ramen-c…` (7m 19s)", notices.NOTICE),
    ("⏳ Working — 12 min — iteration 14/90, waiting for provider response (streaming)", notices.HEARTBEAT),
    ("⏳ Working — 3 min", notices.HEARTBEAT),
    ("Carl's on it — researching Cedar Park ramen now, back with the pick shortly.", None),
    ("**Ramen512** — 1420 Cypress Creek Rd", None),
    ("I'm working on it — give me a minute.", None),
])
def test_classify_matches_hermes_templates(text, kind):
    assert notices.classify(text) == kind


async def test_notices_are_saved_as_system_lines(live, gw):
    await live.send("default", "♻️ Gateway online — Hermes is back and ready.", expect_edits=False)
    assert gw.calls == [("message", "default", "♻️ Gateway online — Hermes is back and ready.", None, 1)]
    assert gw.roles == ["system"]
    await live.send("default", "Carl's on it.", expect_edits=False)
    assert gw.roles == ["system", "assistant"]


async def test_heartbeat_is_dropped_including_later_edits(live, gw):
    mid = await live.send("default", "⏳ Working — 1 min", expect_edits=False)
    assert mid.startswith("heartbeat-")
    assert await live.edit("default", mid, "⏳ Working — 2 min — iteration 3/90", finalize=False)
    assert gw.calls == []


# ---- feedback round 2: tool-activity bubbles and busy-input notices ---------------

@pytest.mark.parametrize("text,kind", [
    # Diane's bubble (her own display.tool_progress outranks Lekora's default)
    ('⚙️ tool_search: "Searching tools · terminal execute co..."\n'
     '⚙️ tool_search: "Searching tools · file read local fil..."', notices.TOOL_PROGRESS),
    ('🧠 hindsight_retain: "Ashlyn seemed down last time"', notices.TOOL_PROGRESS),   # memory add-on tool
    ("⚙️ browser_exec...", notices.TOOL_PROGRESS),
    ('🔍 Searching the web for ramen\n⚙️ tool_search: "x"', notices.TOOL_PROGRESS),
    ("💬 thinking about it\n⚙️ web_fetch...", notices.TOOL_PROGRESS),
    # "Redirected" notice, with and without the emoji-style marker
    ("↪ Redirected current run (4 min elapsed, iteration 16/90, running: terminal). "
     "I'll adjust using your correction.", notices.NOTICE),
    ("↪️ Redirected current run (4 min elapsed). I'll adjust using your correction.", notices.NOTICE),
    ("⏩ Steered into current run. Your message arrives after the next tool call.", notices.NOTICE),
    ("⏳ Queued for the next turn. I'll respond once the current task finishes.", notices.NOTICE),
    # Never hidden: agent messages that merely look a bit like tool lines
    ("✅ done...", None),
    ('🎉 Great news: "it worked"', None),
    ("🔍 Searching now, back soon", None),
    ('⚙️ tool_search: "x"\nAnd here is what I found.', None),
])
def test_classify_round_two(text, kind):
    assert notices.classify(text) == kind


async def test_tool_activity_bubble_and_its_edits_are_dropped(live, gw):
    mid = await live.send("diane", '⚙️ tool_search: "Searching tools"', expect_edits=False)
    assert mid.startswith("tool_progress-")
    assert await live.edit("diane", mid, '⚙️ tool_search: "Searching tools"\n⚙️ terminal...', finalize=False)
    assert gw.calls == []


@pytest.mark.parametrize("text,kind", [
    ("👁️ Hindsight — recalled 181 memories", notices.NOTICE),
    ("🧠 Honcho — recalled 1 memory", notices.NOTICE),
    ("🧠 Mem0 — recalled relevant memory  👁️ Hindsight — recalled 3 memories", notices.NOTICE),
    ("I recalled 3 memories from our trip — want them?", None),
])
def test_memory_recall_line_is_a_system_notice(text, kind):
    assert notices.classify(text) == kind
