"""An agent's tools in Lekora chats (docs/agent-tools.md)."""

import pytest

from lekora.agent_tools import AgentTools, ToolsError
from tests.test_files import ask, fgw, file_store, phone  # noqa: F401  (fixtures)


class FakeHermesTools:
    """Stands in for Hermes' tool settings and its `hermes tools` command."""

    def __init__(self):
        self.enabled = {"web", "terminal", "file"}
        self.runs = []
        self.backups = []
        self.ignore = set()

    def read(self, profile):
        return {"toolsets": [{"key": k, "label": k.title(), "description": "", "enabled": k in self.enabled}
                             for k in ("web", "terminal", "file", "kanban", "tts")],
                "elsewhere": {"telegram": ["kanban", "terminal", "web"]}}

    async def run(self, args):
        self.runs.append(list(args))
        _, profile, _, action, *rest = args
        keys = rest[:rest.index("--platform")]
        assert rest[rest.index("--platform") + 1] == "lekora", "only Lekora's own platform entry"
        for key in keys:
            if key in self.ignore:
                continue
            (self.enabled.add if action == "enable" else self.enabled.discard)(key)
        return 0, "ok"

    def backup(self, profile):
        self.backups.append(profile)


async def test_changes_go_through_hermes_after_a_backup():
    hermes = FakeHermesTools()
    tools = AgentTools(hermes.read, hermes.run, hermes.backup)
    after = await tools.set("brenda", {"kanban": True, "tts": True, "file": False, "web": True})
    assert hermes.backups == ["brenda"]
    assert hermes.runs == [["-p", "brenda", "tools", "enable", "kanban", "tts", "--platform", "lekora"],
                           ["-p", "brenda", "tools", "disable", "file", "--platform", "lekora"]]
    state = {t["key"]: t["enabled"] for t in after["toolsets"]}
    assert state["kanban"] and state["tts"] and not state["file"] and "problem" not in after


async def test_nothing_to_change_writes_nothing():
    hermes = FakeHermesTools()
    tools = AgentTools(hermes.read, hermes.run, hermes.backup)
    await tools.set("brenda", {"web": True})
    assert hermes.runs == [] and hermes.backups == []


async def test_a_change_that_doesnt_stick_is_reported():
    hermes = FakeHermesTools()
    hermes.ignore = {"kanban"}
    after = await AgentTools(hermes.read, hermes.run, hermes.backup).set("brenda", {"kanban": True})
    assert "kanban" in after["problem"], "read back from Hermes, not assumed"


async def test_bad_requests_and_failed_backups():
    hermes = FakeHermesTools()
    tools = AgentTools(hermes.read, hermes.run, hermes.backup)
    with pytest.raises(ToolsError):
        await tools.set("brenda", {"rocket": True})

    def no_backup(profile):
        raise OSError("disk full")

    with pytest.raises(ToolsError) as failed:
        await AgentTools(hermes.read, hermes.run, no_backup).set("brenda", {"kanban": True})
    assert failed.value.code == "BACKUP_FAILED" and hermes.runs == [], "no backup, no change"


async def test_over_the_connection(fgw, store):
    hermes = FakeHermesTools()
    fgw.tools = AgentTools(hermes.read, hermes.run, hermes.backup)
    ws = await phone(fgw, store)
    got = await ask(ws, store, "agent.tools.get", {})
    assert got["data"]["elsewhere"]["telegram"] == ["kanban", "terminal", "web"]
    got = await ask(ws, store, "agent.tools.set", {"changes": {"kanban": True}})
    assert {t["key"]: t["enabled"] for t in got["data"]["toolsets"]}["kanban"] is True
    await ws.close()
