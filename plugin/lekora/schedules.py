"""Schedules (spec: docs/scheduler.md): each agent's Hermes cron jobs, read and changed from the phone.

Jobs are Hermes' (``<agent home>/cron/jobs.json``, history in its execution log and
``cron/output/<job>/``), and Hermes' own scheduler runs them. Everything goes through the same
functions Hermes' dashboard uses, so its rules (schedule parsing, one-shot guards, the scheduler's
registration) apply. Lekora keeps nothing about schedules itself.
"""

from __future__ import annotations

import asyncio
import importlib
import importlib.util
import logging
import re
from datetime import datetime
from pathlib import Path
from typing import Any, Awaitable, Callable, Iterable, Optional

log = logging.getLogger(__name__)

NAME_CHARS = 200
PROMPT_CHARS = 20_000
SCHEDULE_CHARS = 200
RUNS_SHOWN = 30
OUTPUT_CHARS = 60_000
LEKORA = "lekora"


class ScheduleError(Exception):
    def __init__(self, code: str, reason: str) -> None:
        super().__init__(reason)
        self.code = code
        self.reason = reason


def _detail(exc: Exception) -> str:
    """Hermes' words from a dashboard refusal (an HTTPException's ``detail``), or the error's text."""
    detail = getattr(exc, "detail", None)
    if isinstance(detail, dict):
        detail = detail.get("message") or detail.get("detail") or str(detail)
    return str(detail or exc or "Hermes refused").strip()


def _float(value: Any) -> Optional[float]:
    try:
        return float(value) if value is not None else None
    except (TypeError, ValueError):
        return None


def response_of(document: str) -> str:
    """A run's output document: the agent's response when it has one, else the whole document."""
    match = re.search(r"^## Response\s*$", document, flags=re.M)
    text = document[match.end():] if match else document
    return text.strip()[:OUTPUT_CHARS]


def phone_job(job: dict, profile_id: str) -> dict:
    """A Hermes job, as phones see it."""
    schedule = job.get("schedule") or {}
    repeat = job.get("repeat") or {}
    state = job.get("state") or ("scheduled" if job.get("enabled", True) else "paused")
    return {
        "id": job.get("id"), "profile_id": profile_id,
        "name": (job.get("name") or "").strip() or None,
        "prompt": job.get("prompt") or "",
        "schedule": {k: schedule.get(k) for k in ("kind", "display", "expr", "minutes", "run_at") if schedule.get(k) is not None}
        | {"display": job.get("schedule_display") or schedule.get("display") or ""},
        "state": state, "enabled": bool(job.get("enabled", True)),
        "next_run_at": job.get("next_run_at"), "last_run_at": job.get("last_run_at"),
        "last_status": job.get("last_status"),
        "last_error": (str(job.get("last_error") or job.get("last_delivery_error") or "")[:500] or None),
        "deliver": job.get("deliver") or "local",
        "repeat": {"times": repeat.get("times"), "completed": int(repeat.get("completed") or 0)},
        "model": job.get("model") or None,
        "skills": list(job.get("skills") or []),
        "script": bool(job.get("script")) or bool(job.get("no_agent")),
    }


class HermesSchedules:
    """Hermes' cron code, as the plugin uses it. Every method blocks (run it in a thread)."""

    def __init__(self) -> None:
        # Found now; loaded on first use (the dashboard modules take a second to import).
        for name in ("cron.jobs", "hermes_cli.web_server_cron", "hermes_cli.web_routers.cron", "hermes_cli.web_models"):
            if importlib.util.find_spec(name) is None:
                raise ImportError(name)

    @property
    def server(self) -> Any:
        return importlib.import_module("hermes_cli.web_server_cron")

    @property
    def routes(self) -> Any:
        return importlib.import_module("hermes_cli.web_routers.cron")

    @property
    def models(self) -> Any:
        return importlib.import_module("hermes_cli.web_models")

    @property
    def jobs(self) -> Any:
        return importlib.import_module("cron.jobs")

    def _call(self, profile: str, name: str, *args: Any, mutate: bool = False) -> Any:
        fn = self.server._mutate_cron_for_profile if mutate else self.server._call_cron_for_profile
        try:
            return fn(profile, name, *args)
        except ScheduleError:
            raise
        except Exception as exc:
            raise ScheduleError("SCHEDULE_REFUSED", _detail(exc))

    def _job(self, profile: str, job_id: str) -> dict:
        job = self._call(profile, "get_job", job_id) if isinstance(job_id, str) and job_id else None
        if not job:
            raise ScheduleError("UNKNOWN_SCHEDULE", "That schedule isn't on this agent any more")
        return job

    def jobs_file(self, profile: str) -> Path:
        _, home = self.server._cron_profile_home(profile)
        return Path(home) / "cron" / "jobs.json"

    # ---- reading --------------------------------------------------------------------

    def list(self, profile: str) -> list[dict]:
        return list(self._call(profile, "list_jobs", True) or [])

    def get(self, profile: str, job_id: str) -> dict:
        return self._job(profile, job_id)

    def preview(self, text: str) -> dict:
        try:
            schedule = self.jobs.parse_schedule(text)
        except Exception as exc:
            raise ScheduleError("INVALID_SCHEDULE", _detail(exc))
        upcoming: list[str] = []
        last: Optional[str] = None
        for _ in range(3):
            try:
                nxt = self.jobs.compute_next_run(schedule, last)
            except Exception:
                break
            if not nxt or nxt == last:
                break
            upcoming.append(nxt)
            if schedule.get("kind") == "once":
                break
            last = nxt
        return {"kind": schedule.get("kind"), "display": schedule.get("display") or text,
                **{k: schedule[k] for k in ("expr", "minutes", "run_at") if schedule.get(k) is not None},
                "next": upcoming}

    def runs(self, profile: str, job_id: str) -> list[dict]:
        job = self._job(profile, job_id)
        try:
            got = self.routes._list_cron_job_runs_sync(job["id"], profile, RUNS_SHOWN)
        except Exception as exc:
            if getattr(exc, "status_code", None) == 503:
                return []  # an agent whose gateway never started has no history yet
            raise ScheduleError("SCHEDULE_REFUSED", _detail(exc))
        out = []
        for row in got.get("runs") or []:
            title = str(row.get("title") or "")
            failed = bool(re.match(r"\s*(FAILED|ERROR)\b", title)) or "(FAILED)" in title[:200]
            active = str(row.get("is_active")).lower() == "true" or row.get("is_active") is True
            out.append({
                "id": str(row.get("id")), "started_at": _float(row.get("started_at")),
                "ended_at": None if active else _float(row.get("ended_at") or row.get("last_active")),
                "status": "running" if active else ("failed" if failed else "ok"),
                "title": re.sub(r"\s+", " ", re.sub(r"^\s*(COMPLETED|FAILED|ERROR)\s*·\s*", "", title)).strip()[:200] or None,
            })
        return out

    def output(self, profile: str, job_id: str, run_id: str) -> str:
        """What one run produced: its Hermes output document (matched by name, else by time)."""
        job = self._job(profile, job_id)
        _, home = self.server._cron_profile_home(profile)
        folder = Path(home) / "cron" / "output" / job["id"]
        try:
            docs = sorted(p for p in folder.glob("*.md") if p.is_file())
        except OSError:
            docs = []
        if not docs:
            return ""
        stamp = run_id.rsplit(":", 1)[-1] if run_id.startswith("cron_output:") else None
        chosen = next((p for p in docs if stamp and p.stem == stamp), None)
        if chosen is None:
            when = next((r for r in self.runs(profile, job_id) if r["id"] == run_id), None)
            if when is None:
                raise ScheduleError("UNKNOWN_SCHEDULE", "That run isn't kept any more")
            target = when.get("ended_at") or when.get("started_at") or 0

            def at(path: Path) -> float:
                try:
                    return datetime.strptime(path.stem, "%Y-%m-%d_%H-%M-%S").timestamp()
                except ValueError:
                    return path.stat().st_mtime
            chosen = min(docs, key=lambda p: abs(at(p) - target))
            if abs(at(chosen) - target) > 900:
                return ""
        try:
            return response_of(chosen.read_text(errors="replace"))
        except OSError:
            return ""

    # ---- changes --------------------------------------------------------------------

    def create(self, profile: str, fields: dict) -> dict:
        body = self.models.CronJobCreate(**fields)
        try:
            return self.routes._create_cron_job_sync(body, profile)
        except Exception as exc:
            raise ScheduleError("SCHEDULE_REFUSED", _detail(exc))

    def update(self, profile: str, job_id: str, changes: dict) -> dict:
        self._job(profile, job_id)
        try:
            return self.routes._update_cron_job_sync(job_id, self.models.CronJobUpdate(updates=changes), profile)
        except Exception as exc:
            raise ScheduleError("SCHEDULE_REFUSED", _detail(exc))

    def pause(self, profile: str, job_id: str) -> dict:
        self._job(profile, job_id)
        return self._call(profile, "pause_job", job_id, mutate=True)

    def resume(self, profile: str, job_id: str) -> dict:
        self._job(profile, job_id)
        return self._call(profile, "resume_job", job_id, mutate=True)

    def run(self, profile: str, job_id: str) -> dict:
        """Due now: Hermes' own scheduler (in the gateway, with every platform) runs it on its next tick."""
        job = self._job(profile, job_id)
        if job.get("state") == "paused" or not job.get("enabled", True):
            raise ScheduleError("SCHEDULE_REFUSED", "It's paused. Resume it first, then run it")
        return self._call(profile, "trigger_job", job_id, mutate=True)

    def delete(self, profile: str, job_id: str) -> None:
        self._job(profile, job_id)
        if not self._call(profile, "remove_job", job_id, mutate=True):
            raise ScheduleError("UNKNOWN_SCHEDULE", "That schedule isn't on this agent any more")


DRAFT_INSTRUCTIONS = """You turn a person's description of a recurring or one-off task into a Hermes cron job.
Reply with JSON only: {"name": short title (max 6 words), "prompt": the instruction the agent will
receive each time it runs, written to the agent in second person, complete and self-contained (what to do,
what to include in the result), "schedule": when, in one of these forms: "every 30m", "every 2h",
"in 45m", a 5-field cron expression such as "0 9 * * 1-5" (minute hour day-of-month month day-of-week,
0 = Sunday), or an ISO local time "YYYY-MM-DDTHH:MM" for a single run}.
Use the cron form for anything at a time of day. Times are the person's local time. If no time is given,
pick a sensible one (mornings 8:00, evenings 18:00). The agent is called {agent}. Now is {now}."""


class Schedules:
    """Schedules for phones: checks what they send, delivers to Lekora by default, tells phones of changes."""

    def __init__(self, hermes: Any, publish: Callable[[str], Awaitable[None]],
                 profiles: Callable[[], Iterable[str]],
                 llm: Optional[Callable[[str, str], Awaitable[Any]]] = None,
                 agent_name: Callable[[str], str] = lambda profile: profile) -> None:
        self.hermes = hermes        # HermesSchedules (or a stand-in in tests)
        self.publish = publish      # (agent): `schedules.changed` to every phone
        self.profiles = profiles    # the agents
        self.llm = llm              # (instructions, text) -> parsed JSON: Hermes' model for plugins (ctx.llm)
        self.agent_name = agent_name
        self._stamps: dict[str, Optional[float]] = {}

    async def _run(self, fn: Callable, *args: Any) -> Any:
        return await asyncio.to_thread(fn, *args)

    def _profile(self, profile_id: Any) -> str:
        if not isinstance(profile_id, str) or profile_id not in set(self.profiles()):
            raise ScheduleError("UNKNOWN_PROFILE", "There's no such agent on this Hermes instance")
        return profile_id

    # ---- for the phone ---------------------------------------------------------------

    async def request(self, type_: str, profile_id: Any, data: dict) -> dict:
        if type_ == "schedules.list":
            agents = [self._profile(profile_id)] if profile_id else list(self.profiles())

            def read() -> list[dict]:
                out = []
                for agent in agents:
                    try:
                        out += [phone_job(j, agent) for j in self.hermes.list(agent)]
                    except ScheduleError:
                        log.debug("Lekora: couldn't read %s's schedules", agent, exc_info=True)
                return out
            return {"jobs": await self._run(read)}
        if type_ == "schedule.preview":
            return await self._run(self.hermes.preview, self._schedule(data.get("schedule")))

        profile = self._profile(profile_id)
        if type_ == "schedule.draft":
            return await self.draft(profile, self._text(data.get("description"), 2000, "Describe what it should do and when"))
        if type_ == "schedule.create":
            fields: dict[str, Any] = {
                "prompt": self._text(data.get("prompt"), PROMPT_CHARS, "What should the agent do?"),
                "schedule": self._schedule(data.get("schedule")),
                "name": self._text(data.get("name"), NAME_CHARS) or "",
                "deliver": self._deliver(data.get("deliver", LEKORA), profile),
            }
            if data.get("repeat") is not None:
                fields["repeat"] = self._repeat(data.get("repeat"))
            if data.get("model"):
                fields["model"] = self._text(data.get("model"), 200)
            if data.get("skills"):
                fields["skills"] = self._skills(data.get("skills"))
            job = await self._run(self.hermes.create, profile, fields)
            await self._changed(profile)
            return {"job": phone_job(job, profile)}

        job_id = data.get("job_id")
        if not isinstance(job_id, str) or not job_id:
            raise ScheduleError("UNKNOWN_SCHEDULE", "Which schedule?")
        if type_ == "schedule.runs":
            return {"runs": await self._run(self.hermes.runs, profile, job_id)}
        if type_ == "schedule.output":
            run_id = data.get("run_id")
            if not isinstance(run_id, str) or not run_id:
                raise ScheduleError("UNKNOWN_SCHEDULE", "Which run?")
            return {"text": await self._run(self.hermes.output, profile, job_id, run_id)}
        if type_ == "schedule.update":
            job = await self._run(self.hermes.update, profile, job_id, self._changes(data.get("changes"), profile))
        elif type_ == "schedule.pause":
            job = await self._run(self.hermes.pause, profile, job_id)
        elif type_ == "schedule.resume":
            job = await self._run(self.hermes.resume, profile, job_id)
        elif type_ == "schedule.run":
            job = await self._run(self.hermes.run, profile, job_id)
        elif type_ == "schedule.delete":
            await self._run(self.hermes.delete, profile, job_id)
            await self._changed(profile)
            return {"job_id": job_id}
        else:
            raise ScheduleError("INVALID_SCHEDULE", f"Unknown schedule request: {type_}")
        await self._changed(profile)
        return {"job": phone_job(job, profile)}

    async def draft(self, profile: str, description: str) -> dict:
        """A cron job drafted from the person's words, by Hermes' own model; the schedule is checked
        with Hermes (one retry with Hermes' hint). Nothing is created: the person reviews it first."""
        if self.llm is None:
            raise ScheduleError("DRAFT_UNAVAILABLE", "Drafting isn't available on this Hermes instance")
        instructions = DRAFT_INSTRUCTIONS.replace("{agent}", self.agent_name(profile)).replace(
            "{now}", datetime.now().astimezone().strftime("%A %Y-%m-%d %H:%M %Z"))
        text, hint = description, None
        for _ in range(2):
            try:
                got = await self.llm(instructions, text)
            except ScheduleError:
                raise
            except Exception as exc:
                log.info("Lekora: drafting a schedule failed: %s", exc)
                raise ScheduleError("DRAFT_FAILED", "Hermes' model couldn't draft it just now. Try again, or fill it in yourself")
            if not isinstance(got, dict):
                hint = "Reply with the JSON object only."
            else:
                name = str(got.get("name") or "").strip()[:NAME_CHARS]
                prompt = str(got.get("prompt") or "").strip()[:PROMPT_CHARS]
                schedule = " ".join(str(got.get("schedule") or "").split())[:SCHEDULE_CHARS]
                if prompt and schedule:
                    try:
                        preview = await self._run(self.hermes.preview, schedule)
                        return {"name": name or None, "prompt": prompt, "schedule": schedule, "preview": preview}
                    except ScheduleError as exc:
                        hint = f"Hermes couldn't read the schedule {schedule!r}: {exc.reason}"
                else:
                    hint = "Both prompt and schedule are required."
            text = f"{description}\n\n(Your last answer didn't work. {hint})"
        raise ScheduleError("DRAFT_FAILED", "Hermes' model couldn't turn that into a schedule. Try saying when more plainly")

    # ---- checks ----------------------------------------------------------------------

    @staticmethod
    def _text(value: Any, limit: int, required: Optional[str] = None) -> Optional[str]:
        if value is not None and not isinstance(value, str):
            raise ScheduleError("INVALID_SCHEDULE", "Text expected")
        value = (value or "").strip()
        if required and not value:
            raise ScheduleError("INVALID_SCHEDULE", required)
        if len(value) > limit:
            raise ScheduleError("INVALID_SCHEDULE", f"That's too long (up to {limit} characters)")
        return value or None

    def _schedule(self, value: Any) -> str:
        return " ".join(self._text(value, SCHEDULE_CHARS, "When should it run?").split())

    @staticmethod
    def _deliver(value: Any, profile: str) -> str:
        if value in (None, "", LEKORA):
            return f"{LEKORA}:{profile}"
        if not isinstance(value, str) or len(value) > 200 or not value.strip():
            raise ScheduleError("INVALID_SCHEDULE", "Where should the results go?")
        return value.strip()

    @staticmethod
    def _repeat(value: Any) -> Optional[int]:
        if value is None:
            return None
        if isinstance(value, bool) or not isinstance(value, int) or not 1 <= value <= 100_000:
            raise ScheduleError("INVALID_SCHEDULE", "How many times: a whole number, 1 or more")
        return value

    @staticmethod
    def _skills(value: Any) -> list[str]:
        if not isinstance(value, list) or not all(isinstance(s, str) and s.strip() for s in value):
            raise ScheduleError("INVALID_SCHEDULE", "Skills must be names")
        return [s.strip() for s in value][:50]

    def _changes(self, value: Any, profile: str) -> dict:
        if not isinstance(value, dict) or not value:
            raise ScheduleError("INVALID_SCHEDULE", "Nothing to change")
        out: dict[str, Any] = {}
        if "name" in value:
            out["name"] = self._text(value["name"], NAME_CHARS) or ""
        if "prompt" in value:
            out["prompt"] = self._text(value["prompt"], PROMPT_CHARS, "What should the agent do?")
        if "schedule" in value:
            out["schedule"] = self._schedule(value["schedule"])
        if "deliver" in value:
            out["deliver"] = self._deliver(value["deliver"], profile)
        if "repeat" in value:
            out["repeat"] = self._repeat(value["repeat"])
        if "model" in value:
            out["model"] = self._text(value["model"], 200)
        if "skills" in value:
            out["skills"] = self._skills(value["skills"] or []) if value["skills"] else []
        unknown = set(value) - {"name", "prompt", "schedule", "deliver", "repeat", "model", "skills"}
        if unknown:
            raise ScheduleError("INVALID_SCHEDULE", f"Can't change {', '.join(sorted(unknown))} from Lekora")
        return out

    # ---- watching --------------------------------------------------------------------

    async def _changed(self, profile: str) -> None:
        try:
            self._stamps[profile] = await self._run(self._stamp, profile)
            await self.publish(profile)
        except Exception:
            log.debug("Lekora: couldn't tell phones about a schedule change", exc_info=True)

    def _stamp(self, profile: str) -> Optional[float]:
        try:
            return self.hermes.jobs_file(profile).stat().st_mtime_ns
        except (OSError, ScheduleError, Exception):
            return None

    async def check(self) -> None:
        """One look at each agent's jobs file; phones hear about agents whose schedules changed."""
        for profile in list(self.profiles()):
            stamp = await self._run(self._stamp, profile)
            known = profile in self._stamps
            if known and stamp != self._stamps[profile]:
                self._stamps[profile] = stamp
                try:
                    await self.publish(profile)
                except Exception:
                    log.debug("Lekora: couldn't tell phones about a schedule change", exc_info=True)
            else:
                self._stamps[profile] = stamp

    async def watch(self, every: float = 5.0, active: Callable[[], bool] = lambda: True) -> None:
        while True:
            try:
                if active():
                    await self.check()
                else:
                    self._stamps.clear()
            except Exception:
                log.debug("Lekora: schedule check failed", exc_info=True)
            await asyncio.sleep(every)
