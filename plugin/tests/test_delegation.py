"""Helpers as a live tree in the chat (docs/delegation.md)."""

import asyncio
import json

import pytest

from lekora.delegation import Delegations, doing_text
from tests.test_gateway import PROFILES, env, gw, recv  # noqa: F401  (gw fixture)
from tests.test_history import drain, hello_rev


class Clock:
    def __init__(self):
        self.now = 1_800_000_000.0

    def __call__(self):
        return self.now


class FakeHermes:
    """Stands in for Hermes' running-helper list and its Stop."""

    def __init__(self):
        self.stopped = []
        self.alive = set()

    def interrupt(self, helper_id):
        self.stopped.append(helper_id)
        return helper_id in self.alive


@pytest.fixture
def hermes():
    return FakeHermes()


@pytest.fixture
def tick():
    return Clock()


@pytest.fixture
def helpers(gw, store, hermes, tick):
    d = Delegations(store, gw.publish_helpers, gw.update_helpers, interrupt=hermes.interrupt, clock=tick, every=0)
    gw.delegations = d
    return d


async def phone(gw, store, name="iPhone"):
    device_id, tok = store.register_device(name)
    ws = await hello_rev(gw, store, device_id, tok, since_rev=store.current_rev())
    await recv(ws)  # hello.ack
    return ws


def cards(messages):
    return [m["data"] for m in messages if m["type"] == "chat.message" and m["data"].get("delegation")]


async def start(helpers, helper_id, goal="Find flights", parent=None, chat="assistant", turn="t1", agent=None):
    await helpers.started(chat_id=chat, turn=turn, helper_id=helper_id, goal=goal, parent_id=parent,
                          agent=agent, session="s-" + helper_id)


async def test_a_reply_using_helpers_shows_one_card_with_each_helper(gw, store, helpers):
    ws = await phone(gw, store)
    await start(helpers, "sa-0-a", "Find flights")
    await start(helpers, "sa-1-b", "Find hotels")
    got = cards(await drain(ws))
    assert got[0]["role"] == "helpers" and got[0]["text"] == "Using 1 helper (1 working)"
    last = got[-1]
    assert last["seq"] == got[0]["seq"]  # one card, updated in place
    assert [h["goal"] for h in last["delegation"]["helpers"]] == ["Find flights", "Find hotels"]
    assert last["delegation"]["status"] == "working"
    assert all(h["status"] == "working" and h["steps"] == 0 for h in last["delegation"]["helpers"])


async def test_steps_and_doing_now_come_from_its_tools(gw, store, helpers):
    await start(helpers, "sa-0-a")
    ws = await phone(gw, store)
    await helpers.used_tool("sa-0-a", "web_search")
    await helpers.used_tool("sa-0-a", "browser_navigate")
    helper = cards(await drain(ws))[-1]["delegation"]["helpers"][0]
    assert helper["steps"] == 2 and helper["doing"] == "Browser navigate"


async def test_endings_reports_and_times(gw, store, helpers, tick):
    await start(helpers, "sa-0-a")
    await start(helpers, "sa-1-b")
    await start(helpers, "sa-2-c")
    await start(helpers, "sa-3-d")
    ws = await phone(gw, store)
    await helpers.finished(session="s-sa-0-a", status="completed", summary="Two flights found", duration_ms=65000)
    await helpers.finished(session="s-sa-1-b", status="failed", summary=None, duration_ms=1000)
    await helpers.finished(session="s-sa-2-c", status="interrupted")
    await helpers.finished(session="s-sa-3-d", status="timeout")
    last = cards(await drain(ws))[-1]
    h = last["delegation"]["helpers"]
    assert [x["status"] for x in h] == ["done", "failed", "stopped", "timed_out"]
    assert h[0]["summary"] == "Two flights found"
    assert h[0]["started_at"] == "2027-01-15T08:00:00Z" and h[0]["ended_at"] == "2027-01-15T08:01:05Z"
    assert last["delegation"]["status"] == "done" and last["text"] == "Used 4 helpers"


async def test_a_helpers_own_helpers_join_its_branch(gw, store, helpers):
    await start(helpers, "sa-0-a", "Plan the trip")
    await start(helpers, "sa-0-x", "Check visas", parent="sa-0-a", chat=None, turn="other")
    ws = await phone(gw, store)
    await helpers.used_tool("sa-0-x", "web_search")
    h = cards(await drain(ws))[-1]["delegation"]["helpers"]
    assert [(x["id"], x.get("parent")) for x in h] == [("sa-0-a", None), ("sa-0-x", "sa-0-a")]


async def test_another_agent_shows_by_name(gw, store, helpers):
    ws = await phone(gw, store)
    await start(helpers, "sa-0-a", "Review the plan", agent="coder")
    assert cards(await drain(ws))[-1]["delegation"]["helpers"][0]["agent"] == "coder"


async def test_helpers_outside_lekora_chats_are_ignored(gw, store, helpers):
    ws = await phone(gw, store)
    await start(helpers, "sa-0-a", chat=None)
    assert cards(await drain(ws)) == []


async def test_running_list_updates_doing_and_marks_finishing(gw, store, helpers):
    await start(helpers, "sa-0-a")
    ws = await phone(gw, store)
    await helpers.running([{"subagent_id": "sa-0-a", "tool_count": 7, "last_tool": "read_file"}])
    h = cards(await drain(ws))[-1]["delegation"]["helpers"][0]
    assert (h["steps"], h["doing"], h["status"]) == (7, "Read file", "working")
    await helpers.running([])  # left Hermes' list; its report comes when the batch ends
    assert cards(await drain(ws))[-1]["delegation"]["helpers"][0]["status"] == "finishing"


async def test_a_queued_helper_is_not_finishing(gw, store, helpers):
    await start(helpers, "sa-0-a")
    ws = await phone(gw, store)
    await helpers.running([])  # never seen yet: still waiting for a slot
    assert cards(await drain(ws)) == []


async def test_updates_are_sent_at_most_once_a_second(gw, store, hermes, tick):
    d = Delegations(store, gw.publish_helpers, gw.update_helpers, interrupt=hermes.interrupt, clock=tick, every=0.2)
    await d.started(chat_id="assistant", turn="t", helper_id="sa-0-a", goal="g", session="s")
    ws = await phone(gw, store)
    for _ in range(10):
        await d.used_tool("sa-0-a", "web_search")
    await asyncio.sleep(0.4)
    got = cards(await drain(ws))
    assert len(got) == 1 and got[0]["delegation"]["helpers"][0]["steps"] == 10


async def test_stop_one_helper_from_the_phone(gw, store, helpers, hermes):
    await start(helpers, "sa-0-a")
    await start(helpers, "sa-1-b")
    hermes.alive = {"sa-0-a", "sa-1-b"}
    seq = store.working_helper_cards()[0].seq
    ws = await phone(gw, store)
    await ws.send(env(store, "delegation.stop", {"seq": seq, "helper_id": "sa-1-b"}, profile_id="assistant", msg_id="s1"))
    replies = await drain(ws)
    result = next(m for m in replies if m["type"] == "delegation.stop.result")
    assert result["id"] == "s1" and result["data"] == {"stopped": ["sa-1-b"]}
    assert hermes.stopped == ["sa-1-b"]
    assert cards(replies)[-1]["delegation"]["helpers"][1]["doing"] == "Stopping"


async def test_stop_all_stops_every_working_helper(gw, store, helpers, hermes):
    await start(helpers, "sa-0-a")
    await start(helpers, "sa-1-b")
    await start(helpers, "sa-2-c")
    await helpers.finished(session="s-sa-2-c", status="completed")
    hermes.alive = {"sa-0-a", "sa-1-b"}
    seq = store.working_helper_cards()[0].seq
    assert await helpers.stop(seq) == ["sa-0-a", "sa-1-b"]


async def test_stopping_a_finished_card_says_so(gw, store, helpers):
    ws = await phone(gw, store)
    await ws.send(env(store, "delegation.stop", {"seq": 999}, profile_id="assistant", msg_id="s1"))
    err = next(m for m in await drain(ws) if m["type"] == "error")
    assert err["data"]["code"] == "UNKNOWN_CARD"


async def test_card_survives_reconnect(gw, store, helpers):
    await start(helpers, "sa-0-a", "Find flights")
    await helpers.finished(session="s-sa-0-a", status="completed", summary="Found two")
    device_id, tok = store.register_device("later")
    ws = await hello_rev(gw, store, device_id, tok, since_rev=0)
    got = cards(await drain(ws))
    assert got[-1]["delegation"]["helpers"][0]["summary"] == "Found two"


async def test_leftovers_after_a_restart_show_stopped(gw, store, helpers, tick):
    await start(helpers, "sa-0-a")
    await start(helpers, "sa-1-b")
    await helpers.finished(session="s-sa-0-a", status="completed")
    restarted = Delegations(store, gw.publish_helpers, gw.update_helpers, clock=tick, every=0)
    assert await restarted.close_leftovers() == 1
    assert store.working_helper_cards() == []
    ev = store.get_event(store.events_for_profile("assistant")[0].seq)
    h = ev.payload["delegation"]["helpers"]
    assert [x["status"] for x in h] == ["done", "stopped"] and ev.payload["delegation"]["status"] == "done"


async def test_long_reports_are_trimmed(gw, store, helpers):
    await start(helpers, "sa-0-a")
    await helpers.finished(session="s-sa-0-a", status="completed", summary="x" * 9000)
    ev = store.events_for_profile("assistant")[0]
    assert len(store.get_event(ev.seq).payload["delegation"]["helpers"][0]["summary"]) == 4000


def test_tool_names_read_as_words():
    assert doing_text("web_search") == "Web search"
    assert doing_text("mcp_github_create_issue") == "Github create issue"
    assert doing_text("") is None
