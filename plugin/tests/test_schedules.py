"""Schedules (docs/scheduler.md), with a stand-in for Hermes' cron code."""

import pytest

from lekora.schedules import ScheduleError, Schedules, phone_job, response_of
from tests.test_files import fgw, file_store, phone  # noqa: F401  (fixtures)
from tests.test_gateway import env, recv
from tests.test_voice_replies import until


class FakeCron:
    """Hermes' cron as the plugin sees it (HermesSchedules' shape)."""

    def __init__(self, tmp_path) -> None:
        self.jobs = {}      # profile -> {id: job}
        self.n = 0
        self.root = tmp_path
        self.created = []

    def jobs_file(self, profile):
        path = self.root / profile / "jobs.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        if not path.exists():
            path.write_text("[]")
        return path

    def _touch(self, profile):
        path = self.jobs_file(profile)
        path.write_text(str(self.n) + path.read_text())

    def list(self, profile):
        return list(self.jobs.get(profile, {}).values())

    def _job(self, profile, job_id):
        job = self.jobs.get(profile, {}).get(job_id)
        if job is None:
            raise ScheduleError("UNKNOWN_SCHEDULE", "That schedule isn't on this agent any more")
        return job

    def get(self, profile, job_id):
        return self._job(profile, job_id)

    def preview(self, text):
        if text == "weekdays at 9am":
            return {"kind": "cron", "display": text, "expr": "0 9 * * 1-5",
                    "next": ["2026-11-18T09:00:00-06:00", "2026-11-19T09:00:00-06:00", "2026-11-20T09:00:00-06:00"]}
        raise ScheduleError("INVALID_SCHEDULE", "Invalid schedule 'x'. Use: 'every 30m', 'weekdays at 9am'")

    def create(self, profile, fields):
        self.preview(fields["schedule"]) if fields["schedule"] != "every 2h" else None
        self.n += 1
        job = {"id": f"j{self.n}", "name": fields.get("name"), "prompt": fields["prompt"],
               "schedule": {"kind": "cron", "display": fields["schedule"]}, "schedule_display": fields["schedule"],
               "state": "scheduled", "enabled": True, "deliver": fields["deliver"],
               "repeat": {"times": fields.get("repeat"), "completed": 0}, "model": fields.get("model"),
               "skills": fields.get("skills") or []}
        self.created.append(fields)
        self.jobs.setdefault(profile, {})[job["id"]] = job
        self._touch(profile)
        return job

    def update(self, profile, job_id, changes):
        job = self._job(profile, job_id)
        job.update({k: v for k, v in changes.items() if k != "schedule"})
        if "schedule" in changes:
            job["schedule_display"] = changes["schedule"]
        if "repeat" in changes:
            job["repeat"] = {"times": changes["repeat"], "completed": 0}
        self._touch(profile)
        return job

    def pause(self, profile, job_id):
        self._job(profile, job_id).update(state="paused", enabled=False)
        return self._job(profile, job_id)

    def resume(self, profile, job_id):
        self._job(profile, job_id).update(state="scheduled", enabled=True)
        return self._job(profile, job_id)

    def run(self, profile, job_id):
        job = self._job(profile, job_id)
        if job["state"] == "paused":
            raise ScheduleError("SCHEDULE_REFUSED", "It's paused. Resume it first, then run it")
        job["next_run_at"] = "now"
        return job

    def delete(self, profile, job_id):
        self._job(profile, job_id)
        del self.jobs[profile][job_id]

    def runs(self, profile, job_id):
        self._job(profile, job_id)
        return [{"id": "cron_output:j1:2026-11-17_09-00-00", "started_at": 1.0, "ended_at": 2.0, "status": "ok", "title": "Inbox"}]

    def output(self, profile, job_id, run_id):
        self._job(profile, job_id)
        return "Three new emails."


def service(tmp_path, profiles=("assistant", "coder")):
    cron = FakeCron(tmp_path)
    published = []

    async def publish(profile):
        published.append(profile)
    return Schedules(cron, publish, profiles=lambda: list(profiles)), cron, published


async def test_create_delivers_to_lekora_and_lists_every_agent(tmp_path):
    schedules, cron, published = service(tmp_path)
    made = (await schedules.request("schedule.create", "coder", {"prompt": " Summarise my inbox ", "schedule": "weekdays  at 9am",
                                                                  "name": "Inbox"}))["job"]
    assert cron.created[0]["deliver"] == "lekora:coder", "results come to this agent's Lekora chat by default"
    assert cron.created[0]["prompt"] == "Summarise my inbox" and cron.created[0]["schedule"] == "weekdays at 9am"
    assert made["profile_id"] == "coder" and made["schedule"]["display"] == "weekdays at 9am"
    await schedules.request("schedule.create", "assistant", {"prompt": "Check the news", "schedule": "every 2h",
                                                              "deliver": "local", "repeat": 3, "model": "gpt-x",
                                                              "skills": ["news"]})
    assert cron.created[1]["deliver"] == "local" and cron.created[1]["repeat"] == 3 and cron.created[1]["skills"] == ["news"]
    everyone = (await schedules.request("schedules.list", None, {}))["jobs"]
    assert sorted(j["profile_id"] for j in everyone) == ["assistant", "coder"]
    assert [j["name"] for j in (await schedules.request("schedules.list", "coder", {}))["jobs"]] == ["Inbox"]
    assert published == ["coder", "assistant"]


async def test_preview_shows_what_hermes_understood(tmp_path):
    schedules, _, _ = service(tmp_path)
    got = await schedules.request("schedule.preview", None, {"schedule": "weekdays at 9am"})
    assert got["expr"] == "0 9 * * 1-5" and len(got["next"]) == 3
    with pytest.raises(ScheduleError) as err:
        await schedules.request("schedule.preview", None, {"schedule": "whenever"})
    assert err.value.code == "INVALID_SCHEDULE" and "every 30m" in err.value.reason


async def test_edit_pause_resume_run_delete(tmp_path):
    schedules, cron, published = service(tmp_path)
    made = (await schedules.request("schedule.create", "coder", {"prompt": "x", "schedule": "every 2h"}))["job"]
    jid = made["id"]
    got = (await schedules.request("schedule.update", "coder", {"job_id": jid, "changes": {
        "name": "Hourly-ish", "schedule": "weekdays at 9am", "deliver": "lekora", "repeat": None, "model": ""}}))["job"]
    assert got["name"] == "Hourly-ish" and got["schedule"]["display"] == "weekdays at 9am"
    assert cron.jobs["coder"][jid]["deliver"] == "lekora:coder" and cron.jobs["coder"][jid]["model"] is None
    assert (await schedules.request("schedule.pause", "coder", {"job_id": jid}))["job"]["state"] == "paused"
    with pytest.raises(ScheduleError) as err:
        await schedules.request("schedule.run", "coder", {"job_id": jid})
    assert err.value.code == "SCHEDULE_REFUSED" and "Resume" in err.value.reason
    assert (await schedules.request("schedule.resume", "coder", {"job_id": jid}))["job"]["state"] == "scheduled"
    assert (await schedules.request("schedule.run", "coder", {"job_id": jid}))["job"]["next_run_at"] == "now"
    runs = (await schedules.request("schedule.runs", "coder", {"job_id": jid}))["runs"]
    assert runs[0]["status"] == "ok"
    assert (await schedules.request("schedule.output", "coder", {"job_id": jid, "run_id": runs[0]["id"]}))["text"] == "Three new emails."
    assert (await schedules.request("schedule.delete", "coder", {"job_id": jid})) == {"job_id": jid}
    assert cron.list("coder") == []


async def test_bad_requests_are_refused_plainly(tmp_path):
    schedules, _, _ = service(tmp_path)
    for type_, profile, data, code in (
            ("schedule.create", "nobody", {"prompt": "x", "schedule": "every 2h"}, "UNKNOWN_PROFILE"),
            ("schedule.create", "coder", {"prompt": "  ", "schedule": "every 2h"}, "INVALID_SCHEDULE"),
            ("schedule.create", "coder", {"prompt": "x", "schedule": ""}, "INVALID_SCHEDULE"),
            ("schedule.create", "coder", {"prompt": "x", "schedule": "every 2h", "repeat": 0}, "INVALID_SCHEDULE"),
            ("schedule.create", "coder", {"prompt": "x", "schedule": "every 2h", "skills": "news"}, "INVALID_SCHEDULE"),
            ("schedule.pause", "coder", {"job_id": "missing"}, "UNKNOWN_SCHEDULE"),
            ("schedule.update", "coder", {"job_id": "missing", "changes": {}}, "INVALID_SCHEDULE"),
            ("schedule.runs", "coder", {}, "UNKNOWN_SCHEDULE")):
        with pytest.raises(ScheduleError) as err:
            await schedules.request(type_, profile, data)
        assert err.value.code == code, (type_, data)
    made = (await schedules.request("schedule.create", "coder", {"prompt": "x", "schedule": "every 2h"}))["job"]
    with pytest.raises(ScheduleError) as err:
        await schedules.request("schedule.update", "coder", {"job_id": made["id"], "changes": {"script": "rm -rf /"}})
    assert "script" in err.value.reason, "only what the app offers can be changed"


async def test_changes_made_elsewhere_are_noticed(tmp_path):
    schedules, cron, published = service(tmp_path)
    await schedules.check()
    assert published == []
    cron.n += 1
    cron._touch("assistant")  # e.g. a run finished, or an agent added one
    await schedules.check()
    assert published == ["assistant"]
    await schedules.check()
    assert published == ["assistant"]


def test_shapes():
    job = phone_job({"id": "a", "name": " ", "prompt": "p", "schedule": {"kind": "interval", "minutes": 120, "display": "every 120m"},
                     "schedule_display": "every 120m", "enabled": False, "repeat": None, "deliver": "telegram",
                     "no_agent": True}, "carl")
    assert job["name"] is None and job["state"] == "paused" and job["schedule"]["minutes"] == 120
    assert job["repeat"] == {"times": None, "completed": 0} and job["script"] is True and job["deliver"] == "telegram"
    doc = "# Cron Job: Inbox\n\n## Prompt\n\nSummarise\n\n## Response\n\nThree new emails.\n"
    assert response_of(doc) == "Three new emails."
    assert response_of("# Cron Job: x (FAILED)\n\nGatewayUnavailableError") .startswith("# Cron Job: x (FAILED)")


async def test_the_phone_uses_schedules(fgw, store, tmp_path):
    schedules, cron, _ = service(tmp_path, profiles=("assistant", "coder"))
    fgw.schedules = Schedules(cron, fgw.publish_schedules_changed, profiles=lambda: ["assistant", "coder"])
    ws = await phone(fgw, store)
    other = await phone(fgw, store)

    async def send(type_, data, profile="coder"):
        await ws.send(env(store, type_, data, profile_id=profile, msg_id=type_))
        while True:
            got = await recv(ws)
            if got["type"] != "schedules.changed":
                return got

    got = await send("schedule.create", {"prompt": "Summarise my inbox", "schedule": "weekdays at 9am"})
    assert got["type"] == "schedule.create.result" and got["data"]["job"]["deliver"] == "lekora:coder"
    changed = (await until(other, "schedules.changed"))[0]
    assert changed["profile_id"] == "coder"
    got = await send("schedules.list", {}, profile=None)
    assert got["type"] == "schedules.list.result" and len(got["data"]["jobs"]) == 1
    got = await send("schedule.preview", {"schedule": "nonsense"}, profile=None)
    assert got["type"] == "error" and got["data"]["code"] == "INVALID_SCHEDULE"
    await ws.close()
    await other.close()


async def test_without_schedules_the_phone_is_told(fgw, store):
    ws = await phone(fgw, store)
    await ws.send(env(store, "schedules.list", {}, msg_id="x"))
    got = await recv(ws)
    assert got["type"] == "error" and got["data"]["code"] == "SCHEDULES_UNAVAILABLE"
    await ws.close()
