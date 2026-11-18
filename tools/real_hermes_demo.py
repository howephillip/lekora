"""A pretend Hermes instance that uses Hermes' REAL board and scheduler code, in a throwaway Hermes
home (never your own). For checking the Board and Schedules in the simulator.

Run with Hermes' own Python (it needs Hermes' modules):
    <Hermes venv>/bin/python tools/real_hermes_demo.py      (prints a pairing link)
"""
import asyncio, io, os, sys, tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "plugin"))

PROFILES = [
    {"profile_id": "default", "name": "Default", "avatar": "sparkles"},
    {"profile_id": "scout", "name": "Scout", "avatar": "sparkles"},
    {"profile_id": "juniper", "name": "Juniper", "avatar": "sparkles"},
]


def hermes_home(tmp: Path) -> Path:
    home = tmp / "hermes-home"
    home.mkdir()
    (home / "config.yaml").write_text("model: demo\n")
    for p in PROFILES[1:]:
        (home / "profiles" / p["profile_id"]).mkdir(parents=True)
        (home / "profiles" / p["profile_id"] / "config.yaml").write_text("model: demo\n")
    os.environ["HERMES_HOME"] = str(home)  # before any Hermes module reads it
    from hermes_state import SessionDB
    SessionDB(home / "state.db").close()
    return home


def seed(schedules, boards) -> None:
    schedules.create("default", {"prompt": "Summarise my unread email and tell me what needs a reply.",
                                 "schedule": "0 7 * * 1-5", "name": "Morning inbox", "deliver": "lekora:default"})
    schedules.create("default", {"prompt": "Check the weather for the weekend.", "schedule": "0 18 * * 5",
                                 "deliver": "telegram"})
    cafe = schedules.create("scout", {"prompt": "Look for new cafes near the office.", "schedule": "every 6h",
                                      "deliver": "local", "name": "Cafe watch"})
    schedules.pause("scout", cafe["id"])
    boards.create("default", title="Plan the launch party", body=None, assignee="scout", priority=1,
                  parents=[], triage=False, author="demo")


class Bridge:
    """Messages to agents go nowhere here."""
    async def deliver_to_agent(self, *args, **kwargs):
        return "ok"

    def __getattr__(self, name):
        async def nothing(*args, **kwargs):
            return None
        return nothing


async def stand_in_drafter(instructions, text):
    """No model here (and no cost): a fixed draft, so the Describe It screen can be checked."""
    await asyncio.sleep(1.5)
    return {"name": "Morning inbox", "prompt": "Summarise my unread email and tell me what needs a reply.",
            "schedule": "0 8 * * 1-5"}


async def main():
    tmp = Path(tempfile.mkdtemp(prefix="lekora-real-hermes-"))
    hermes_home(tmp)
    from lekora.kanban import HermesBoards
    from lekora.pairing import run_pair
    from lekora.plugin import LekoraConfig, LekoraService
    from lekora.schedules import HermesSchedules
    schedules, boards = HermesSchedules(), HermesBoards()
    seed(schedules, boards)
    cfg = LekoraConfig(db_path=str(tmp / "lekora.db"), listen_host="127.0.0.1",
                       instance_name="Real Hermes Demo", extra_hosts=["127.0.0.1"], profiles=PROFILES)
    svc = LekoraService(Bridge(), cfg, hermes_version="0.22.5", kanban_boards=boards, hermes_schedules=schedules,
                        draft_llm=stand_in_drafter)
    await svc.start()
    out = io.StringIO()
    run_pair(svc.store, out, extra_hosts=["127.0.0.1"], listening=lambda p: True)
    print(out.getvalue(), flush=True)
    await asyncio.Event().wait()

asyncio.run(main())
