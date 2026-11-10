"""Approval and question cards (docs/prompts.md)."""

import asyncio
import json
from datetime import datetime, timezone

import pytest

from lekora.prompts import Prompts, Resolvers
from tests.test_gateway import PROFILES, env, gw, hello, recv  # noqa: F401  (gw fixture)
from tests.test_history import drain, hello_rev


class FakeHermes:
    """Stands in for Hermes' approval and clarify functions."""

    def __init__(self):
        self.approvals = []      # (session_key, choice, reason)
        self.answers = []        # (clarify_id, text)
        self.pending_approvals = 1
        self.pending_questions = {"q1"}
        self.waiting_now = None  # what `waiting` reports; None = can't tell

    def resolvers(self):
        def approve(session_key, choice, reason):
            self.approvals.append((session_key, choice, reason))
            if self.pending_approvals <= 0:
                return 0
            self.pending_approvals -= 1
            return 1

        def answer(clarify_id, text):
            self.answers.append((clarify_id, text))
            if clarify_id in self.pending_questions:
                self.pending_questions.discard(clarify_id)
                return True
            return False

        return Resolvers(approve=approve, answer=answer, approval_timeout=lambda: 300,
                         waiting=lambda kind, session_key, clarify_id: self.waiting_now)


NOW = datetime(2026, 11, 8, 23, 10, tzinfo=timezone.utc)


@pytest.fixture
def hermes():
    return FakeHermes()


@pytest.fixture
def prompts(gw, hermes):
    p = Prompts(lambda: gw, hermes.resolvers(), clock=lambda: NOW)
    p.recheck_delay = 0
    gw.prompts = p
    return p


async def phone(gw, store, name="iPhone"):
    device_id, tok = store.register_device(name)
    ws = await hello_rev(gw, store, device_id, tok, since_rev=store.current_rev())
    await recv(ws)  # hello.ack
    return ws


def respond(store, card_id, msg_id="r1", profile="assistant", **data):
    return env(store, "prompt.respond", dict(card_id=card_id, **data), profile_id=profile, msg_id=msg_id)


async def ask_approval(prompts, choices=("once", "session", "always", "deny"), smart_denied=False):
    message_id = await prompts.ask_approval("assistant", "sess-1", "rm -rf ./build", "recursive delete",
                                            list(choices), smart_denied=smart_denied)
    return message_id[len("card-"):]


# ---- approvals -------------------------------------------------------------------

async def test_approval_card_reaches_every_phone(gw, store, prompts):
    a, b = await phone(gw, store, "a"), await phone(gw, store, "b")
    card_id = await ask_approval(prompts)
    for ws in (a, b):
        msg = await recv(ws)
        assert msg["type"] == "chat.message" and msg["data"]["role"] == "approval"
        assert msg["data"]["text"] == "Wants to run: rm -rf ./build"
        card = msg["data"]["card"]
        assert card == {"kind": "approval", "id": card_id, "status": "pending", "command": "rm -rf ./build",
                        "description": "recursive delete", "choices": ["once", "session", "always", "deny"],
                        "smart_denied": False, "expires_at": "2026-11-08T23:15:00Z"}
    await a.close(); await b.close()


@pytest.mark.parametrize("choice,status", [("once", "allowed_once"), ("session", "allowed_session"),
                                           ("always", "allowed_always")])
async def test_allow_choices_go_to_hermes(gw, store, prompts, hermes, choice, status):
    ws = await phone(gw, store)
    card_id = await ask_approval(prompts)
    await recv(ws)
    await ws.send(respond(store, card_id, choice=choice))
    got = await drain(ws)
    ack = next(m for m in got if m["type"] == "prompt.respond.ack")
    assert ack["id"] == "r1" and ack["data"] == {"card_id": card_id, "status": status}
    update = next(m for m in got if m["type"] == "chat.message")
    assert update["data"]["card"]["status"] == status
    assert hermes.approvals == [("sess-1", choice, None)]
    await ws.close()


async def test_deny_with_reason(gw, store, prompts, hermes):
    ws = await phone(gw, store)
    card_id = await ask_approval(prompts)
    await recv(ws)
    await ws.send(respond(store, card_id, choice="deny", reason="  not on the build machine  "))
    got = await drain(ws)
    assert hermes.approvals == [("sess-1", "deny", "not on the build machine")]
    card = next(m for m in got if m["type"] == "chat.message")["data"]["card"]
    assert card["status"] == "denied" and card["reason"] == "not on the build machine"
    await ws.close()


async def test_only_offered_choices_are_accepted(gw, store, prompts, hermes):
    ws = await phone(gw, store)
    card_id = await ask_approval(prompts, choices=["once", "deny"], smart_denied=True)
    first = await recv(ws)
    assert first["data"]["card"]["choices"] == ["once", "deny"] and first["data"]["card"]["smart_denied"]
    await ws.send(respond(store, card_id, choice="always"))
    err = await recv(ws)
    assert err["type"] == "error" and err["data"]["code"] == "INVALID_ANSWER"
    assert hermes.approvals == []
    await ws.close()


async def test_hermes_no_longer_waiting_marks_it_expired(gw, store, prompts, hermes):
    hermes.pending_approvals = 0
    ws = await phone(gw, store)
    card_id = await ask_approval(prompts)
    await recv(ws)
    await ws.send(respond(store, card_id, choice="once"))
    got = await drain(ws)
    assert next(m for m in got if m["type"] == "prompt.respond.ack")["data"]["status"] == "expired"
    await ws.close()


async def test_second_answer_gets_the_current_state(gw, store, prompts, hermes):
    a, b = await phone(gw, store, "a"), await phone(gw, store, "b")
    card_id = await ask_approval(prompts)
    await recv(a); await recv(b)
    await a.send(respond(store, card_id, choice="once"))
    await drain(a)
    assert (await recv(b))["data"]["card"]["status"] == "allowed_once"   # the other phone updates
    await b.send(respond(store, card_id, choice="deny", msg_id="r2"))
    ack = await recv(b)
    assert ack["type"] == "prompt.respond.ack" and ack["data"]["status"] == "allowed_once"
    assert len(hermes.approvals) == 1, "answered once only"
    await a.close(); await b.close()


async def test_unknown_card(gw, store, prompts):
    ws = await phone(gw, store)
    await ws.send(respond(store, "c_nope", choice="once"))
    assert (await recv(ws))["data"]["code"] == "UNKNOWN_CARD"
    await ws.close()


async def test_timeout_edit_closes_the_card(gw, store, prompts):
    ws = await phone(gw, store)
    card_id = await ask_approval(prompts)
    await recv(ws)
    assert await prompts.approval_timed_out(card_id)
    assert (await recv(ws))["data"]["card"]["status"] == "timed_out"
    assert not await prompts.approval_timed_out(card_id)
    await ws.close()


async def test_typed_approve_closes_approvals_once_hermes_acted(gw, store, prompts, hermes):
    ws = await phone(gw, store)
    card_id = await ask_approval(prompts)
    await recv(ws)
    hermes.waiting_now = False   # Hermes resolved it from the typed /approve
    await ws.send(env(store, "chat.send", {"text": "/approve"}, profile_id="assistant"))
    got = await drain(ws, timeout=0.5)
    cards = [m["data"]["card"] for m in got if m["type"] == "chat.message" and "card" in m["data"]]
    assert cards and cards[-1]["status"] == "answered_in_chat" and cards[-1]["id"] == card_id
    await ws.close()


async def test_card_stays_while_hermes_still_waits(gw, store, prompts, hermes):
    ws = await phone(gw, store)
    await ask_approval(prompts)
    await recv(ws)
    hermes.waiting_now = True
    await prompts.turn_ended("assistant")   # e.g. a queued message's turn, not this one
    await ws.send(env(store, "chat.send", {"text": "/approve"}, profile_id="assistant"))
    got = await drain(ws, timeout=0.3)
    assert not [m for m in got if "card" in m.get("data", {})]
    assert prompts.pending_count() == 1
    await ws.close()


# ---- questions -------------------------------------------------------------------

async def ask_question(prompts, choices=("Ramen512", "Kemuri"), multi=False, clarify_id="q1"):
    message_id = await prompts.ask_question("assistant", "sess-1", "Which venue?", list(choices) if choices else None,
                                            clarify_id, multi_select=multi)
    return message_id[len("card-"):]


async def test_question_card_and_choice_answer(gw, store, prompts, hermes):
    ws = await phone(gw, store)
    card_id = await ask_question(prompts)
    msg = await recv(ws)
    assert msg["data"]["role"] == "question" and msg["data"]["text"] == "Asks: Which venue?"
    assert msg["data"]["card"]["choices"] == ["Ramen512", "Kemuri"] and not msg["data"]["card"]["multi_select"]
    await ws.send(respond(store, card_id, answers=["Kemuri"]))
    got = await drain(ws)
    assert hermes.answers == [("q1", "Kemuri")]
    card = next(m for m in got if m["type"] == "chat.message")["data"]["card"]
    assert card["status"] == "answered" and card["answer"] == "Kemuri"
    await ws.close()


async def test_multi_select_and_typed_answers(gw, store, prompts, hermes):
    hermes.pending_questions = {"q1", "q2"}
    ws = await phone(gw, store)
    multi = await ask_question(prompts, choices=["Mon", "Tue", "Wed"], multi=True, clarify_id="q1")
    other = await ask_question(prompts, clarify_id="q2")
    await drain(ws)
    await ws.send(respond(store, multi, answers=["Tue", "Mon"]))
    await drain(ws)
    await ws.send(respond(store, other, msg_id="r2", text="Somewhere quiet"))
    await drain(ws)
    assert hermes.answers == [("q1", json.dumps(["Tue", "Mon"])), ("q2", "Somewhere quiet")]
    await ws.close()


async def test_single_choice_question_rejects_two_answers_and_unknown_options(gw, store, prompts, hermes):
    ws = await phone(gw, store)
    card_id = await ask_question(prompts)
    await recv(ws)
    for data in ({"answers": ["Ramen512", "Kemuri"]}, {"answers": ["Elsewhere"]}, {"text": "  "}):
        await ws.send(respond(store, card_id, **data))
        assert (await recv(ws))["data"]["code"] == "INVALID_ANSWER"
    assert hermes.answers == []
    await ws.close()


async def test_retired_question_closes(gw, store, prompts):
    ws = await phone(gw, store)
    await ask_question(prompts)
    await recv(ws)
    await prompts.question_retired("q1")
    assert (await recv(ws))["data"]["card"]["status"] == "closed"
    await ws.close()


async def test_turn_end_closes_whatever_hermes_stopped_waiting_on(gw, store, prompts, hermes):
    ws = await phone(gw, store)
    await ask_question(prompts)
    await ask_approval(prompts)
    await drain(ws)
    hermes.waiting_now = False
    await prompts.turn_ended("assistant")
    statuses = [m["data"]["card"]["status"] for m in await drain(ws)]
    assert statuses == ["closed", "closed"]
    await ws.close()


# ---- restarts and history --------------------------------------------------------

async def test_cards_from_a_previous_run_expire_on_startup(gw, store, prompts):
    await ask_approval(prompts)
    await ask_question(prompts)
    fresh = Prompts(lambda: gw)   # Hermes restarted: nothing is waiting any more
    assert await fresh.expire_leftovers() == 2
    assert store.pending_cards() == []
    device_id, tok = store.register_device()
    ws = await hello_rev(gw, store, device_id, tok, since_rev=0)
    await recv(ws)
    assert [m["data"]["card"]["status"] for m in await drain(ws)] == ["expired", "expired"]
    await ws.close()


async def test_card_from_a_past_run_answered_gets_its_status(gw, store, prompts):
    card_id = await ask_approval(prompts)
    fresh = Prompts(lambda: gw)
    await fresh.expire_leftovers()
    gw.prompts = fresh
    ws = await phone(gw, store)
    await ws.send(respond(store, card_id, choice="once"))
    ack = await recv(ws)
    assert ack["type"] == "prompt.respond.ack" and ack["data"]["status"] == "expired"
    await ws.close()


async def test_service_wires_prompts_and_expires_leftovers(tmp_path):
    from lekora.plugin import LekoraConfig, LekoraService

    class Bridge:
        async def deliver_to_agent(self, profile_id, text, message_id):
            pass

    cfg = LekoraConfig(db_path=str(tmp_path / "lekora.db"), listen_host="127.0.0.1",
                       profiles=[{"profile_id": "assistant", "name": "A", "avatar": "x"}])
    svc = LekoraService(Bridge(), cfg, check_version=False)
    await svc.start()
    await svc.prompts.ask_approval("assistant", "s", "ls", "why", ["once", "deny"])
    await svc.stop()
    svc2 = LekoraService(Bridge(), cfg, check_version=False)
    await svc2.start()
    try:
        assert svc2.gateway.prompts is svc2.prompts
        assert svc2.store.pending_cards() == []
    finally:
        await svc2.stop()


# ---- slash-command confirmations (/new) ------------------------------------------------

HERMES_NEW_PROMPT = ("⚠️ **Confirm /new**\n\nThis starts a fresh session and discards the current conversation history."
                     "\n\nChoose:\n• **Approve Once** — proceed this time only\n• **Always Approve** — proceed and "
                     "silence this prompt permanently\n• **Cancel** — keep current conversation\n\n"
                     "_Text fallback: reply `/approve`, `/always`, or `/cancel`._")


@pytest.fixture
def confirmer():
    calls = []

    async def confirm(session_key, confirm_id, choice):
        calls.append((session_key, confirm_id, choice))
        if confirm_id == "gone":
            return False, None
        return True, ("✨ New session started." if choice != "cancel" else "Cancelled /new.")
    return calls, confirm


async def ask_confirm(prompts, confirm_id="7"):
    message_id = await prompts.ask_confirm("assistant", "sess-1", "⚠️ **Confirm /new**", HERMES_NEW_PROMPT, confirm_id)
    return message_id[len("card-"):]


async def test_confirmation_card_shows_only_what_it_does(gw, store, prompts):
    ws = await phone(gw, store)
    card_id = await ask_confirm(prompts)
    msg = await recv(ws)
    assert msg["data"]["role"] == "confirm" and msg["data"]["text"] == "Confirm /new"
    card = msg["data"]["card"]
    assert card["id"] == card_id and card["title"] == "Confirm /new"
    assert card["description"] == "This starts a fresh session and discards the current conversation history."
    assert card["choices"] == ["once", "always", "cancel"] and card["expires_at"] == "2026-11-08T23:15:00Z"
    await ws.close()


@pytest.mark.parametrize("choice,status,follow_up", [("once", "confirmed_once", "✨ New session started."),
                                                     ("cancel", "cancelled", "Cancelled /new.")])
async def test_confirmation_runs_through_hermes(gw, store, prompts, confirmer, choice, status, follow_up):
    calls, confirm = confirmer
    prompts.resolvers.confirm = confirm
    ws = await phone(gw, store)
    card_id = await ask_confirm(prompts)
    await recv(ws)
    await ws.send(respond(store, card_id, choice=choice))
    got = await drain(ws)
    assert calls == [("sess-1", "7", choice)]
    assert next(m for m in got if m["type"] == "prompt.respond.ack")["data"]["status"] == status
    messages = [m["data"] for m in got if m["type"] == "chat.message"]
    assert messages[0]["card"]["status"] == status
    assert {"role": "system", "text": follow_up}.items() <= messages[1].items()   # Hermes' result as a small line
    await ws.send(respond(store, card_id, choice="once", msg_id="r2"))   # a second tap does nothing
    assert (await recv(ws))["data"]["status"] == status and len(calls) == 1
    await ws.close()


async def test_confirmation_hermes_dropped_is_expired(gw, store, prompts, confirmer):
    calls, confirm = confirmer
    prompts.resolvers.confirm = confirm
    ws = await phone(gw, store)
    card_id = await ask_confirm(prompts, confirm_id="gone")
    await recv(ws)
    await ws.send(respond(store, card_id, choice="once"))
    ack = next(m for m in await drain(ws) if m["type"] == "prompt.respond.ack")
    assert ack["data"]["status"] == "expired"
    await ws.close()


async def test_any_typed_message_rechecks_a_confirmation(gw, store, prompts, hermes):
    ws = await phone(gw, store)
    await ask_confirm(prompts)
    await recv(ws)
    hermes.waiting_now = False   # Hermes dropped it when the next message arrived
    await ws.send(env(store, "chat.send", {"text": "never mind"}, profile_id="assistant"))
    cards = [m["data"]["card"] for m in await drain(ws, timeout=0.5) if "card" in m.get("data", {})]
    assert cards and cards[-1]["status"] == "answered_in_chat"
    await ws.close()


# ---- pickers: /model and choices (/reasoning, /fast) ------------------------------------

PROVIDERS = [
    {"slug": "anthropic", "name": "Anthropic", "models": ["claude-opus-5-5", "claude-sonnet-5-5"],
     "is_current": True, "total_models": 2, "source": "built-in"},
    {"slug": "openrouter", "name": "OpenRouter", "models": ["x/fast-1"], "is_current": False,
     "total_models": 120, "model_labels": {"x/fast-1": "Free"}},
]


async def ask_model(prompts, picked):
    async def on_selected(chat_id, model, provider):
        picked.append((chat_id, model, provider))
        return f"Model switched to `{model}`\nProvider: {provider}"
    message_id = await prompts.ask_model("assistant", "sess-1", PROVIDERS, "claude-opus-5-5", "anthropic", on_selected)
    return message_id[len("card-"):]


async def test_model_picker_card_and_switch(gw, store, prompts):
    picked = []
    ws = await phone(gw, store)
    card_id = await ask_model(prompts, picked)
    msg = await recv(ws)
    card = msg["data"]["card"]
    assert msg["data"]["role"] == "model" and msg["data"]["text"] == "Choose a model (now claude-opus-5-5)"
    assert card["current_model"] == "claude-opus-5-5" and card["current_provider"] == "anthropic"
    assert card["providers"][1] == {"slug": "openrouter", "name": "OpenRouter", "models": ["x/fast-1"],
                                    "is_current": False, "total_models": 120, "model_labels": {"x/fast-1": "Free"}}
    await ws.send(respond(store, card_id, model="claude-sonnet-5-5", provider="anthropic"))
    got = await drain(ws)
    assert picked == [("assistant", "claude-sonnet-5-5", "anthropic")]
    assert next(m for m in got if m["type"] == "prompt.respond.ack")["data"]["status"] == "chosen"
    updates = [m["data"] for m in got if m["type"] == "chat.message"]
    assert updates[0]["card"]["status"] == "chosen"
    assert updates[0]["card"]["chosen"] == {"model": "claude-sonnet-5-5", "provider": "anthropic", "provider_name": "Anthropic"}
    assert updates[1]["role"] == "system" and updates[1]["text"].startswith("Model switched to")
    await ws.close()


async def test_expensive_model_asks_first(gw, store, prompts):
    picked = []
    prompts.resolvers.model_warning = lambda model, provider: "This model costs $75 per million output tokens."
    ws = await phone(gw, store)
    card_id = await ask_model(prompts, picked)
    await recv(ws)
    await ws.send(respond(store, card_id, model="claude-opus-5-5", provider="anthropic"))
    ack = await recv(ws)
    assert ack["data"] == {"card_id": card_id, "status": "needs_confirmation",
                           "message": "This model costs $75 per million output tokens."}
    assert picked == []
    await ws.send(respond(store, card_id, msg_id="r2", model="claude-opus-5-5", provider="anthropic", confirmed=True))
    await drain(ws)
    assert picked == [("assistant", "claude-opus-5-5", "anthropic")]
    await ws.close()


async def test_model_not_offered_is_rejected(gw, store, prompts):
    ws = await phone(gw, store)
    card_id = await ask_model(prompts, [])
    await recv(ws)
    await ws.send(respond(store, card_id, model="claude-opus-5-5", provider="openrouter"))
    assert (await recv(ws))["data"]["code"] == "INVALID_ANSWER"
    await ws.close()


async def test_new_picker_replaces_the_old_one_and_typing_leaves_it(gw, store, prompts, hermes):
    ws = await phone(gw, store)
    first = await ask_model(prompts, [])
    await recv(ws)
    hermes.waiting_now = False
    await prompts.turn_ended("assistant")                       # pickers aren't Hermes turns
    await ws.send(env(store, "chat.send", {"text": "hello"}, profile_id="assistant"))
    assert not [m for m in await drain(ws, timeout=0.3) if "card" in m.get("data", {})]
    second = await ask_model(prompts, [])
    got = [m["data"]["card"] for m in await drain(ws) if "card" in m.get("data", {})]
    assert [(c["id"], c["status"]) for c in got] == [(first, "closed"), (second, "pending")]
    await ws.close()


async def test_choice_picker(gw, store, prompts):
    chosen = []

    async def on_choice(chat_id, value):
        chosen.append(value)
        return f"Reasoning set to {value} (this session)"
    ws = await phone(gw, store)
    message_id = await prompts.ask_choice("assistant", "sess-1", "**Reasoning**: medium (session)",
                                          [{"value": "low", "label": "Low", "is_current": False},
                                           {"value": "medium", "label": "Medium", "is_current": True}], on_choice)
    card_id = message_id[len("card-"):]
    msg = await recv(ws)
    assert msg["data"]["role"] == "choice" and msg["data"]["card"]["options"][1]["is_current"]
    assert msg["data"]["card"]["title"] == "**Reasoning**: medium (session)"
    await ws.send(respond(store, card_id, choice="high"))
    assert (await recv(ws))["data"]["code"] == "INVALID_ANSWER"
    await ws.send(respond(store, card_id, msg_id="r2", choice="low"))
    got = await drain(ws)
    assert chosen == ["low"]
    card = next(m for m in got if m["type"] == "chat.message")["data"]["card"]
    assert card["status"] == "chosen" and card["answer"] == "Low"
    assert any(m["data"].get("text") == "Reasoning set to low (this session)" for m in got if m["type"] == "chat.message")
    await ws.close()


async def test_failing_picker_callback(gw, store, prompts):
    async def broken(*args):
        raise RuntimeError("provider down")
    ws = await phone(gw, store)
    message_id = await prompts.ask_choice("assistant", "s", "Fast mode", [{"value": "on", "label": "On"}], broken)
    await recv(ws)
    await ws.send(respond(store, message_id[len("card-"):], choice="on"))
    ack = next(m for m in await drain(ws) if m["type"] == "prompt.respond.ack")
    assert ack["data"]["status"] == "failed"
    await ws.close()



async def test_model_for_this_chat_or_as_the_default_uses_hermes_own_flags(gw, store, prompts):
    sent = []

    async def send_command(chat_id, text):
        sent.append((chat_id, text))
    prompts.send_command = send_command
    prompts.resolvers.model_warning = lambda model, provider: "pricey"   # Hermes checks it itself on this path
    picked = []
    ws = await phone(gw, store)
    card_id = await ask_model(prompts, picked)
    await recv(ws)
    await ws.send(respond(store, card_id, model="claude-sonnet-5-5", provider="anthropic", scope="global"))
    got = await drain(ws)
    assert next(m for m in got if m["type"] == "prompt.respond.ack")["data"]["status"] == "chosen"
    card = next(m for m in got if m["type"] == "chat.message")["data"]["card"]
    assert card["chosen"]["scope"] == "global"
    assert sent == [("assistant", "/model claude-sonnet-5-5 --provider anthropic --global")]
    assert picked == [], "not through the picker callback"
    second = await ask_model(prompts, picked)
    await drain(ws)
    await ws.send(respond(store, second, msg_id="r2", model="x/fast-1", provider="openrouter", scope="session"))
    await drain(ws)
    assert sent[-1] == ("assistant", "/model x/fast-1 --provider openrouter --session")
    await ws.close()
