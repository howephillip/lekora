"""Analytics: usage and spend across every agent (docs/analytics.md)."""

import datetime as dt

import pytest

from lekora.analytics import Analytics, AnalyticsError
from tests.test_gateway import env, gw, recv  # noqa: F401  (gw fixture)
from tests.test_history import drain, hello_rev

NOW = dt.datetime(2026, 11, 21, 15, 0).timestamp()
TODAY, YESTERDAY = "2026-11-21", "2026-11-20"

USAGE = {
    "assistant": {"main": [{"day": TODAY, "source": "lekora", "sessions": 2, "cost_usd": 0.10, "tokens": 1000},
                           {"day": YESTERDAY, "source": "cron", "sessions": 1, "cost_usd": 0.02, "tokens": 300}],
                  "background": [{"day": TODAY, "cost_usd": 0.01, "tokens": 50}],
                  "models": [{"model": "anthropic/claude-sonnet-5-5", "provider": "openrouter", "cost_usd": 0.12, "tokens": 1250}]},
    "coder": {"main": [{"day": TODAY, "source": "subagent", "sessions": 1, "cost_usd": 0.30, "tokens": 4000}],
              "models": [{"model": "openai/gpt-x", "provider": "openai", "cost_usd": 0.30, "tokens": 4000}]},
}


class Source:
    def __init__(self):
        self.reads, self.account_calls = [], 0

    def read_usage(self, profile, since):
        self.reads.append((profile, since))
        return USAGE.get(profile, {})

    def accounts(self, pairs):
        self.account_calls += 1
        return [{"provider": "openrouter", "title": "Account limits", "windows": [],
                 "details": ["API key usage: $5.00 total • $0.40 today"], "agents": [p for p, prov in pairs if prov == "openrouter"]}]


@pytest.fixture
def source():
    return Source()


@pytest.fixture
def analytics(source):
    return Analytics(lambda: ["assistant", "coder"], source.read_usage, source.accounts,
                     configured_provider=lambda p: "openrouter" if p == "assistant" else None, clock=lambda: NOW)


async def test_seven_days_add_up_every_agent(analytics, source):
    got = await analytics.get(7)
    assert got["totals"] == {"cost_usd": 0.43, "tokens": 5350, "sessions": 4}
    assert [d["day"] for d in got["daily"]][0] == "2026-11-15" and len(got["daily"]) == 7
    assert got["daily"][-1] == {"day": TODAY, "cost_usd": 0.41, "tokens": 5050}
    assert got["daily"][-2] == {"day": YESTERDAY, "cost_usd": 0.02, "tokens": 300}
    assert [a["profile_id"] for a in got["by_agent"]] == ["coder", "assistant"]
    assert got["by_agent"][1] == {"profile_id": "assistant", "cost_usd": 0.13, "tokens": 1350, "sessions": 3}
    assert {s["source"]: s["cost_usd"] for s in got["by_source"]} == {"subagent": 0.3, "lekora": 0.1, "cron": 0.02, "background": 0.01}
    assert [m["model"] for m in got["by_model"]] == ["openai/gpt-x", "anthropic/claude-sonnet-5-5"]
    assert got["estimated"] is True and got["since"] == "2026-11-15"
    assert got["accounts"][0]["agents"] == ["assistant"]


async def test_today_starts_at_local_midnight(analytics, source):
    got = await analytics.get(1)
    assert source.reads[0][1] == dt.datetime(2026, 11, 21).timestamp() and len(got["daily"]) == 1


async def test_one_agents_numbers(analytics):
    got = await analytics.get(30, "coder")
    assert got["totals"]["cost_usd"] == 0.3 and [a["profile_id"] for a in got["by_agent"]] == ["coder"]
    assert len(got["daily"]) == 30


async def test_an_agent_without_usage_still_shows(source):
    a = Analytics(lambda: ["assistant", "quiet"], source.read_usage, clock=lambda: NOW)
    got = await a.get(7)
    assert {"profile_id": "quiet", "cost_usd": 0.0, "tokens": 0, "sessions": 0} in got["by_agent"]
    assert got["accounts"] == []


async def test_account_checks_are_kept_five_minutes(source):
    clock = [NOW]
    a = Analytics(lambda: ["assistant"], source.read_usage, source.accounts, clock=lambda: clock[0])
    await a.get(7)
    await a.get(1)
    assert source.account_calls == 1
    clock[0] += 301
    await a.get(7)
    assert source.account_calls == 2


async def test_bad_requests(analytics):
    with pytest.raises(AnalyticsError):
        await analytics.get(5)
    with pytest.raises(AnalyticsError):
        await analytics.get(7, "nobody")


async def test_a_failing_agent_store_doesnt_break_the_rest():
    def read(profile, since):
        if profile == "broken":
            raise OSError("locked")
        return USAGE["coder"]
    got = await Analytics(lambda: ["broken", "coder"], read, clock=lambda: NOW).get(7)
    assert got["totals"]["cost_usd"] == 0.3


async def test_the_phone_asks(gw, store, analytics):
    gw.analytics = analytics
    device_id, tok = store.register_device("iPhone")
    ws = await hello_rev(gw, store, device_id, tok, since_rev=store.current_rev())
    await recv(ws)
    await ws.send(env(store, "analytics.get", {"days": 7}, msg_id="a1"))
    got = [m for m in await drain(ws) if m.get("id") == "a1"][0]
    assert got["type"] == "analytics.get.result" and got["data"]["totals"]["sessions"] == 4
    await ws.send(env(store, "analytics.get", {"days": 3}, msg_id="a2"))
    err = [m for m in await drain(ws) if m.get("id") == "a2"][0]
    assert err["type"] == "error" and err["data"]["code"] == "INVALID_REQUEST"
