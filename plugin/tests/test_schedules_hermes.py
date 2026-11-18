"""Schedules against Hermes' real cron code (docs/scheduler.md). Runs only where Hermes is installed,
in a temporary Hermes home (never the instance's own jobs)."""

import pytest

pytest.importorskip("cron.jobs")
pytest.importorskip("hermes_cli.web_routers.cron")

from lekora.schedules import HermesSchedules, ScheduleError, phone_job  # noqa: E402


@pytest.fixture
def hermes(tmp_path, monkeypatch):
    home = tmp_path / "hermes-home"
    home.mkdir()
    (home / "config.yaml").write_text("model: test\n")
    monkeypatch.setenv("HERMES_HOME", str(home))
    from hermes_state import SessionDB  # what the gateway does when it starts
    SessionDB(home / "state.db").close()
    got = HermesSchedules()
    assert str(got.jobs_file("default")).startswith(str(home)), "a throwaway home, never the real one"
    return got


def test_preview(hermes):
    got = hermes.preview("weekdays at 9am")
    assert got["kind"] == "cron" and got["expr"] == "0 9 * * 1-5" and len(got["next"]) == 3
    every = hermes.preview("every 2h")
    assert every["kind"] == "interval" and every["minutes"] == 120
    once = hermes.preview("in 30m")
    assert once["kind"] == "once" and len(once["next"]) == 1
    with pytest.raises(ScheduleError) as err:
        hermes.preview("whenever you like")
    assert err.value.code == "INVALID_SCHEDULE" and "every 30m" in err.value.reason


def test_every_action(hermes):
    job = hermes.create("default", {"prompt": "Summarise my inbox", "schedule": "weekdays at 9am", "name": "Inbox",
                                    "deliver": "lekora:default", "repeat": 5, "skills": []})
    shown = phone_job(job, "default")
    assert shown["deliver"] == "lekora:default" and shown["schedule"]["expr"] == "0 9 * * 1-5"
    assert shown["repeat"]["times"] == 5 and shown["state"] == "scheduled" and shown["next_run_at"]
    assert [j["id"] for j in hermes.list("default")] == [job["id"]]

    edited = hermes.update("default", job["id"], {"name": "Morning inbox", "schedule": "every 2h", "repeat": None})
    assert edited["name"] == "Morning inbox" and edited["schedule"]["kind"] == "interval"
    assert (edited.get("repeat") or {}).get("times") is None
    with pytest.raises(ScheduleError) as err:
        hermes.update("default", job["id"], {"schedule": "whenever"})
    assert err.value.code == "SCHEDULE_REFUSED"

    assert hermes.pause("default", job["id"])["state"] == "paused"
    with pytest.raises(ScheduleError):
        hermes.run("default", job["id"])
    assert hermes.resume("default", job["id"])["state"] == "scheduled"
    due = hermes.run("default", job["id"])
    assert due.get("manual_run_at") and due["next_run_at"] == due["manual_run_at"], "due at the next tick"

    assert hermes.runs("default", job["id"]) == []
    hermes.delete("default", job["id"])
    assert hermes.list("default") == []
    with pytest.raises(ScheduleError) as err:
        hermes.get("default", job["id"])
    assert err.value.code == "UNKNOWN_SCHEDULE"


def test_an_agent_whose_gateway_never_ran_has_no_history_yet(hermes):
    job = hermes.create("default", {"prompt": "x", "schedule": "every 2h", "deliver": "local"})
    (hermes.jobs_file("default").parent.parent / "state.db").unlink()
    assert hermes.runs("default", job["id"]) == []


def test_a_runs_output_is_read(hermes):
    job = hermes.create("default", {"prompt": "x", "schedule": "every 2h", "deliver": "local"})
    folder = hermes.jobs_file("default").parent / "output" / job["id"]
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "2026-11-17_09-00-00.md").write_text("# Cron Job: x\n\n## Prompt\n\nx\n\n## Response\n\nAll quiet today.\n")
    runs = hermes.runs("default", job["id"])
    assert runs and runs[0]["status"] == "ok"
    assert hermes.output("default", job["id"], runs[0]["id"]) == "All quiet today."


def test_hermes_scheduler_accepts_lekora_chats_as_a_destination(hermes, monkeypatch):
    """Owner, 2026-11-17: "lekora is not a known delivery target". The platform must tell Hermes it
    takes scheduled results; then `lekora:<agent>` passes Hermes' checks and goes to that agent's chat."""
    pytest.importorskip("gateway.platform_registry")
    from cron import scheduler_delivery as delivery, scheduler_preflight as preflight
    from gateway.platform_registry import PlatformEntry, platform_registry
    from lekora import hermes_adapter

    home = hermes.jobs_file("default").parent.parent
    (home / "config.yaml").write_text("model: test\nplatforms:\n  lekora:\n    enabled: true\n")

    class Ctx:
        def __getattr__(self, name):
            return lambda *a, **k: None

        def register_platform(self, name, label, adapter_factory, check_fn, validate_config=None,
                              required_env=None, install_hint="", **kw):
            platform_registry.register(PlatformEntry(
                name=name, label=label, adapter_factory=adapter_factory, check_fn=check_fn,
                validate_config=validate_config, required_env=required_env or [], install_hint=install_hint,
                source="plugin", plugin_name="lekora", **kw))

    hermes_adapter.register(Ctx())
    job = {"id": "x", "name": "x", "deliver": "lekora:default"}
    assert delivery._is_known_delivery_platform("lekora")
    assert preflight._preflight_check_delivery(job) is None
    target = delivery._resolve_single_delivery_target(job, "lekora:default")
    assert target["platform"] == "lekora" and target["chat_id"] == "default"
    assert hermes_adapter.lekora_target("../etc") is None


async def _no_model(**kw):  # stands in for the model call only (no money spent)
    import json as _json
    from types import SimpleNamespace
    _no_model.seen = kw
    body = _json.dumps({"name": "Inbox", "prompt": "Summarise my unread email.", "schedule": "0 9 * * 1-5"})
    response = SimpleNamespace(choices=[SimpleNamespace(message=SimpleNamespace(content=body))], usage=None, model="stand-in")
    return "stand-in", "stand-in", response  # (provider, model, response), as Hermes' caller returns


def test_drafting_goes_through_hermes_model_for_plugins(hermes):
    """Hermes' own PluginLlm (trust gate, JSON parsing) with the model call stood in."""
    import asyncio
    pytest.importorskip("agent.plugin_llm")
    from agent.plugin_llm import PluginLlm
    from lekora import hermes_adapter
    from lekora.schedules import Schedules

    class Ctx:
        llm = PluginLlm(plugin_id="lekora", async_caller=_no_model)

    async def run():
        hermes_adapter._PLUGIN_CTX = Ctx()
        schedules = Schedules(hermes, publish=lambda p: asyncio.sleep(0), profiles=lambda: ["default"],
                              llm=hermes_adapter._draft_llm)
        return await schedules.request("schedule.draft", "default", {"description": "weekday mornings, my inbox"})
    try:
        got = asyncio.run(run())
    finally:
        hermes_adapter._PLUGIN_CTX = None
    assert got["schedule"] == "0 9 * * 1-5" and got["preview"]["kind"] == "cron" and len(got["preview"]["next"]) == 3
    assert hermes.list("default") == [], "a draft creates nothing"
