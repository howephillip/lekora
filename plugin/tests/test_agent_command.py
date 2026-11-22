"""The lekora command: Lekora's tools for every agent (docs/agent-command.md)."""

import asyncio
import json
import os
import stat
import sys

import pytest

from lekora import agent_command
from lekora.agent_bridge import MANAGED_MARKER, SKILL_NAME, AgentBridge, ensure_skill, install_command, skill_text
from lekora.artifacts import call_tool
from lekora.skills import SkillError, frontmatter
from tests.test_artifacts import PAGE, service
from tests.test_files import fgw, file_store  # noqa: F401  (fixtures)
from tests.test_skills import cli, home, read, skills  # noqa: F401  (fixtures)

IN_CHAT = {"HERMES_SESSION_PLATFORM": "lekora", "HERMES_SESSION_CHAT_ID": "coder", "HERMES_SESSION_PROFILE": "coder"}


async def run_command(command: str, *args: str, env: dict = IN_CHAT, stdin: bytes = b""):
    """Runs the installed command as an agent's terminal would: a separate process, Hermes' session vars."""
    proc = await asyncio.create_subprocess_exec(
        command, *args, stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE, env={**{k: v for k, v in os.environ.items() if not k.startswith("HERMES_")}, **env})
    out, err = await proc.communicate(stdin)
    return proc.returncode, json.loads(out or b"{}"), err.decode()


def test_command_lines_become_the_same_requests_as_the_tools(tmp_path):
    page = tmp_path / "plan.html"
    page.write_text(PAGE)
    p = agent_command._parser()

    def req(*argv):
        return agent_command.request_for(p.parse_args(list(argv)))

    assert req("artifact", "create", "--title", "Plan", "--kind", "html", "--file", str(page)) == (
        "lekora_create_artifact", {"title": "Plan", "kind": "html", "content": PAGE})
    assert req("artifact", "create", "--title", "S", "--kind", "code", "--language", "python", "--content", "x=1")[1][
        "language"] == "python"
    assert req("artifact", "update", "art_1", "--content", "new", "--note", "n") == (
        "lekora_update_artifact", {"artifact_id": "art_1", "content": "new", "note": "n"})
    assert req("artifact", "edit", "art_1", "--edits", '{"find": "a", "replace": "b"}') == (
        "lekora_edit_artifact", {"artifact_id": "art_1", "edits": [{"find": "a", "replace": "b"}]})
    assert req("artifact", "read", "art_1", "--version", "2") == ("lekora_read_artifact", {"artifact_id": "art_1", "version": 2})
    assert req("artifact", "list") == ("lekora_list_artifacts", {})
    assert req("send-file", str(page), "--caption", "hi") == (
        "lekora_send_file", {"path": str(page.resolve()), "caption": "hi"})


def test_outside_a_lekora_chat_it_says_so(capsys, tmp_path):
    code = agent_command.main(["--bridge", str(tmp_path / "bridge.json"), "artifact", "list"],
                              env={"HERMES_SESSION_PLATFORM": "telegram", "HERMES_SESSION_CHAT_ID": "1"})
    assert code == 1 and "Lekora chat" in json.loads(capsys.readouterr().out)["error"]


async def test_an_agent_makes_an_artifact_by_command_and_it_shows_in_its_chat(fgw, store, tmp_path):
    artifacts = service(fgw, store)
    calls = []

    async def run(tool, args, chat_id):
        calls.append((tool, chat_id))
        return await call_tool(tool, args, chat_id, artifacts)

    bridge = AgentBridge(tmp_path / "lekora-command", run)
    await bridge.start()
    command = install_command(tmp_path / "lekora-command", python=sys.executable)
    assert stat.S_IMODE(os.stat(bridge.info_path).st_mode) == 0o600, "the token is for this user only"
    page = tmp_path / "plan.html"
    page.write_text(PAGE)

    code, made, err = await run_command(command, "artifact", "create", "--title", "Plan", "--kind", "html", "--file", str(page))
    assert code == 0 and made["success"] and made["artifact_id"].startswith("art_"), err
    assert calls == [("lekora_create_artifact", "coder")], "in the chat Hermes said the command came from"
    assert artifacts.list("coder")[0]["title"] == "Plan"

    code, edited, _ = await run_command(command, "artifact", "edit", made["artifact_id"],
                                        "--edits", '[{"find": "Ramen", "replace": "Udon"}]')
    assert code == 0 and edited["version"] == 2
    code, got, _ = await run_command(command, "artifact", "read", made["artifact_id"])
    assert "Udon night" in got["content"]
    code, piped, _ = await run_command(command, "artifact", "update", made["artifact_id"], "--file", "-", stdin=b"# New")
    assert piped["version"] == 3
    code, missing, _ = await run_command(command, "artifact", "read", "art_nope")
    assert code == 1 and not missing["success"]

    await bridge.stop()
    assert not bridge.info_path.exists()
    code, gone, _ = await run_command(command, "artifact", "list")
    assert code == 1 and "isn't running" in gone["error"]


async def test_a_wrong_token_or_request_is_refused(tmp_path):
    async def run(tool, args, chat_id):
        raise AssertionError("must not run")

    bridge = AgentBridge(tmp_path, run)
    await bridge.start()
    info = json.loads(bridge.info_path.read_text())
    for line in (json.dumps({"token": "nope", "tool": "lekora_list_artifacts", "args": {}, "chat_id": "coder"}),
                 json.dumps({"token": info["token"], "tool": "terminal", "args": {}, "chat_id": "coder"}),
                 json.dumps({"token": info["token"], "tool": "lekora_list_artifacts", "args": {}, "chat_id": ""}),
                 "not json"):
        reader, writer = await asyncio.open_connection("127.0.0.1", info["port"])
        writer.write(line.encode() + b"\n")
        await writer.drain()
        answer = json.loads(await reader.readline())
        writer.close()
        assert answer["success"] is False
    await bridge.stop()


async def test_files_go_through_the_same_delivery_as_the_tool(tmp_path):
    from lekora.hermes_files import send_file_async
    sent = []

    async def deliver(chat_id, path, caption, name):
        sent.append((chat_id, path, caption))
        return "It opens as an artifact."

    report = tmp_path / "report.pdf"
    report.write_bytes(b"%PDF-1.4")
    ok = json.loads(await send_file_async({"path": str(report), "caption": "Here"}, "g.abc.coder", deliver,
                                          lambda p: p if os.path.isfile(p) else None))
    assert ok["success"] and "report.pdf" in ok["message"] and sent == [("g.abc.coder", str(report), "Here")]
    bad = json.loads(await send_file_async({"path": "/nope"}, "coder", deliver, lambda p: None))
    assert not bad["success"]


def test_every_agent_gets_lekoras_skill_and_it_stays_current(tmp_path):
    agent = tmp_path / "bruce"
    assert ensure_skill(agent, "/x/lekora") is True
    skill_md = agent / "skills" / "lekora" / SKILL_NAME / "SKILL.md"
    head = frontmatter(skill_md.read_text())
    assert head["name"] == SKILL_NAME and len(head["description"]) <= 60, "within Hermes' limits"
    assert "/x/lekora artifact create" in skill_md.read_text()
    assert ensure_skill(agent, "/x/lekora") is False, "unchanged: not rewritten"
    assert ensure_skill(agent, "/y/lekora") is True and "/y/lekora" in skill_md.read_text(), "a moved command is updated"
    theirs = tmp_path / "carl"
    folder = theirs / "skills" / "lekora" / SKILL_NAME
    folder.mkdir(parents=True)
    (folder / "SKILL.md").write_text("mine")
    assert ensure_skill(theirs, "/x/lekora") is False and (folder / "SKILL.md").read_text() == "mine", \
        "a skill Lekora didn't make is left alone"
    assert skill_text("/x/lekora").count("/x/lekora") >= 6


def test_lekoras_skill_shows_as_lekoras_and_can_only_be_turned_off(skills, home):
    ensure_skill(home, "/x/lekora")
    got = {s["name"]: s for s in skills.list("default")}[SKILL_NAME]
    assert got["source"] == "lekora" and got["enabled"] and got["category"] == "lekora"
    assert (home / "skills" / "lekora" / SKILL_NAME / MANAGED_MARKER).exists()
    with pytest.raises(SkillError):
        asyncio.run(skills.remove("default", SKILL_NAME))
    with pytest.raises(SkillError):
        skills.save("default", skill_text("/x/lekora"), create=False, name=SKILL_NAME)
    skills.set_enabled("default", SKILL_NAME, False)
    assert SKILL_NAME in read(home / "config.yaml")["skills"]["disabled"]
    assert ensure_skill(home, "/x/lekora") is False
    assert SKILL_NAME in read(home / "config.yaml")["skills"]["disabled"], "Lekora respects the user's off"
