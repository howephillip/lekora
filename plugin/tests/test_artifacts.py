"""Artifacts: pages, documents and code the agent makes, with versions (docs/artifacts.md)."""

import asyncio
import json
import threading

import pytest

from lekora.artifacts import ArtifactError, Artifacts, run_tool
from tests.test_files import ask, fgw, file_store, phone  # noqa: F401  (fixtures)
from tests.test_gateway import env, recv
from tests.test_voice_replies import until

PAGE = "<!doctype html><h1>Ramen night</h1><script>document.title='ok'</script>"


def service(fgw, store):
    fgw.artifacts = Artifacts(store, fgw.publish_artifact_message, fgw.publish_artifact_changed)
    return fgw.artifacts


async def test_the_agent_makes_one_and_it_shows_as_a_card(fgw, store):
    artifacts = service(fgw, store)
    ws = await phone(fgw, store)
    made = await artifacts.create("coder", "  Ramen   night ", "html", PAGE)
    message = (await until(ws, "chat.message"))[0]["data"]
    assert message["role"] == "assistant" and message["artifact"]["title"] == "Ramen night"
    assert message["artifact"]["action"] == "created" and message["artifact"]["version"] == 1
    assert made["artifact_id"].startswith("art_") and made["kind"] == "html"
    changed = (await until(ws, "artifact.changed"))[0]["data"]["artifact"]
    assert changed["artifact_id"] == made["artifact_id"]
    await ws.close()


async def test_versions_are_kept_and_the_user_can_edit(fgw, store):
    artifacts = service(fgw, store)
    made = await artifacts.create("coder", "Plan", "markdown", "# Plan\n- one")
    await artifacts.update("coder", made["artifact_id"], "# Plan\n- one\n- two", note="added two")
    edited = await artifacts.update("coder", made["artifact_id"], "# Plan\n- mine", author="user", base=2)
    assert edited["version"] == 3
    with pytest.raises(ArtifactError) as stale:
        await artifacts.update("coder", made["artifact_id"], "# old", author="user", base=2)
    assert stale.value.code == "ARTIFACT_CHANGED", "an edit from an older version never overwrites a newer one"
    got = artifacts.read("coder", made["artifact_id"])
    assert got["content"] == "# Plan\n- mine" and got["shown_version"] == 3
    assert [v["author"] for v in got["versions"]] == ["user", "agent", "agent"]
    assert artifacts.read("coder", made["artifact_id"], 1)["content"] == "# Plan\n- one"
    events = store.recent_messages(10)
    assert [e.payload["artifact"]["action"] for e in events if e.payload.get("artifact")] == ["created", "updated", "edited"]
    assert [e.payload["role"] for e in events if e.payload.get("artifact")][-1] == "user", "your edit shows as yours"


async def test_each_agent_sees_only_its_own(fgw, store):
    artifacts = service(fgw, store)
    made = await artifacts.create("coder", "Mine", "code", "print(1)", language="python")
    assert made["language"] == "python"
    with pytest.raises(ArtifactError):
        artifacts.read("writer", made["artifact_id"])
    assert artifacts.list("writer") == [] and artifacts.list("coder")[0]["title"] == "Mine"
    for bad in ({"title": "", "kind": "html", "content": "x"}, {"title": "t", "kind": "pdf", "content": "x"},
                {"title": "t", "kind": "html", "content": "  "}):
        with pytest.raises(ArtifactError):
            await artifacts.create("coder", bad["title"], bad["kind"], bad["content"])


async def test_the_agents_tools(fgw, store):
    artifacts = service(fgw, store)
    loop = asyncio.get_running_loop()

    def call(name, args, platform="lekora"):
        out = {}
        thread = threading.Thread(target=lambda: out.update(json.loads(run_tool(
            name, args, platform=platform, chat_id="coder", service=artifacts, loop=loop))))
        thread.start()
        return out, thread

    async def run(name, args, platform="lekora"):
        out, thread = call(name, args, platform)
        while thread.is_alive():
            await asyncio.sleep(0.01)
        return out

    made = await run("lekora_create_artifact", {"title": "Chart", "kind": "html", "content": PAGE})
    assert made["success"] and made["version"] == 1
    updated = await run("lekora_update_artifact", {"artifact_id": made["artifact_id"], "content": PAGE + "<p>2</p>"})
    assert updated["version"] == 2
    read = await run("lekora_read_artifact", {"artifact_id": made["artifact_id"]})
    assert read["content"].endswith("<p>2</p>") and read["versions"][0]["by"] == "an agent"
    listed = await run("lekora_list_artifacts", {})
    assert listed["artifacts"][0]["artifact_id"] == made["artifact_id"]
    assert not (await run("lekora_list_artifacts", {}, platform="telegram"))["success"], "only in Lekora chats"
    assert not (await run("lekora_read_artifact", {"artifact_id": "art_nope"}))["success"]


async def test_the_phone_lists_opens_and_saves(fgw, store):
    artifacts = service(fgw, store)
    made = await artifacts.create("coder", "Notes", "text", "hello")
    ws = await phone(fgw, store)
    got = await ask(ws, store, "artifacts.list", {})
    assert got["data"]["artifacts"][0]["title"] == "Notes"
    got = await ask(ws, store, "artifact.get", {"artifact_id": made["artifact_id"]})
    assert got["data"]["content"] == "hello" and got["data"]["versions"][0]["version"] == 1
    await ws.send(env(store, "artifact.save", {"artifact_id": made["artifact_id"], "content": "hello there",
                                               "base_version": 1}, profile_id="coder"))
    got = (await until(ws, "artifact.save.result"))[0]
    assert got["data"]["artifact"]["version"] == 2
    await ws.send(env(store, "artifact.save", {"artifact_id": made["artifact_id"], "content": "x", "base_version": 1},
                      profile_id="coder"))
    got = (await until(ws, "error"))[0]
    assert got["data"]["code"] == "ARTIFACT_CHANGED"
    await ws.close()


async def test_what_a_page_remembers_is_kept_for_the_next_opening(fgw, store, db_path):
    artifacts = service(fgw, store)
    made = await artifacts.create("coder", "Counter", "html", PAGE)
    ws = await phone(fgw, store)
    got = await ask(ws, store, "artifact.state.save", {"artifact_id": made["artifact_id"], "state": {"count": "5"}})
    assert got["data"]["saved"] is True
    got = await ask(ws, store, "artifact.get", {"artifact_id": made["artifact_id"]})
    assert got["data"]["page_state"] == {"count": "5"}
    await artifacts.update("coder", made["artifact_id"], PAGE + "<p>v2</p>")
    assert artifacts.read("coder", made["artifact_id"])["page_state"] == {"count": "5"}, "kept across versions"
    from lekora.store import Store
    assert Store(db_path).artifact_page_state(made["artifact_id"]) == {"count": "5"}, "kept on the Hermes instance"
    for bad in ({"count": 5}, ["x"], {"big": "x" * 1_000_001}):
        await ws.send(env(store, "artifact.state.save", {"artifact_id": made["artifact_id"], "state": bad},
                          profile_id="coder"))
        assert (await until(ws, "error"))[0]["data"]["code"] in ("INVALID_ARTIFACT", "TOO_LARGE")
    await ws.send(env(store, "artifact.state.save", {"artifact_id": made["artifact_id"], "state": {"a": "b"}},
                      profile_id="other"))
    assert (await until(ws, "error"))[0]["data"]["code"] in ("UNKNOWN_ARTIFACT", "UNKNOWN_PROFILE")
    await ask(ws, store, "artifact.state.save", {"artifact_id": made["artifact_id"], "state": {}})
    assert "page_state" not in artifacts.read("coder", made["artifact_id"]), "cleared"
    await ws.close()


async def test_asking_to_change_one_tells_the_agent_which(fgw, store):
    artifacts = service(fgw, store)
    made = await artifacts.create("coder", "Plan", "markdown", "# Plan")
    ws = await phone(fgw, store)
    await ws.send(env(store, "chat.send", {"text": "Add a budget section",
                                           "about": {"artifact_id": made["artifact_id"]}}, profile_id="coder"))
    saved = None
    while saved is None:
        msg = await recv(ws, timeout=3)
        if msg["type"] == "chat.message" and msg["data"]["role"] == "user":
            saved = msg["data"]
    assert saved["text"] == "Add a budget section" and saved["about"]["title"] == "Plan"
    for _ in range(100):
        if fgw.received:
            break
        await asyncio.sleep(0.02)
    sent = fgw.received[-1][1]
    assert sent.startswith("Add a budget section") and made["artifact_id"] in sent
    await ws.close()


async def test_deleting_an_agent_clears_its_artifacts_after_backing_them_up(fgw, store):
    artifacts = service(fgw, store)
    made = await artifacts.create("coder", "Keep", "text", "v1")
    await artifacts.update("coder", made["artifact_id"], "v2")
    exported = store.artifacts_export("coder")
    assert [v["content"] for v in exported[0]["versions"]] == ["v1", "v2"], "every version goes into the backup"
    store.delete_profile_events("coder")
    assert store.list_artifacts("coder") == [] and store.get_artifact(made["artifact_id"]) is None


async def test_a_review_sends_every_line_comment_together(fgw, store):
    artifacts = service(fgw, store)
    made = await artifacts.create("coder", "Script", "code", "import os\nprint(os.name)\nx = 1\n", language="python")
    ws = await phone(fgw, store)
    review = [{"line_start": 3, "line_end": 3, "quote": "x = 1", "comment": "Name this better"},
              {"line_start": 1, "line_end": 2, "quote": "import os\nprint(os.name)", "comment": "Use pathlib"},
              {"line_start": 2, "comment": "   "}]
    await ws.send(env(store, "chat.send", {"text": "Two things", "about": {"artifact_id": made["artifact_id"]},
                                           "review": review}, profile_id="coder"))
    saved = None
    while saved is None:
        msg = await recv(ws, timeout=3)
        if msg["type"] == "chat.message" and msg["data"]["role"] == "user":
            saved = msg["data"]
    assert len(saved["review"]) == 2, "an empty comment is dropped"
    assert saved["text"] == "Two things" and saved["about"]["title"] == "Script"
    for _ in range(100):
        if fgw.received:
            break
        await asyncio.sleep(0.02)
    sent = fgw.received[-1][1]
    assert sent.startswith('Review of the artifact "Script"') and made["artifact_id"] in sent
    assert sent.index("1. Lines 1-2:") < sent.index("2. Line 3:"), "in line order"
    assert "   > import os" in sent and "Use pathlib" in sent and "Two things" in sent

    # A review with no overall note is fine; a review without an artifact isn't a review.
    await ws.send(env(store, "chat.send", {"about": {"artifact_id": made["artifact_id"]}, "review": review[:1]},
                      profile_id="coder"))
    got = None
    while got is None:
        msg = await recv(ws, timeout=3)
        if msg["type"] == "chat.message" and msg["data"]["role"] == "user":
            got = msg["data"]
    assert got["text"] == "" and len(got["review"]) == 1
    await ws.close()


async def test_line_edits_and_find_replace(fgw, store):
    artifacts = service(fgw, store)
    made = await artifacts.create("coder", "Docker", "code", "FROM python:3.12\nRUN a\nRUN b\nCMD x", language="dockerfile")
    edited = await artifacts.edit("coder", made["artifact_id"], [
        {"line_start": 1, "replacement": "FROM python:3.11"},
        {"line_start": 3, "line_end": 3, "replacement": ""},
        {"find": "CMD x", "replace": "CMD y"},
    ], note="review")
    assert edited["version"] == 2
    assert artifacts.read("coder", made["artifact_id"])["content"] == "FROM python:3.11\nRUN a\nCMD y"
    with pytest.raises(ArtifactError):
        await artifacts.edit("coder", made["artifact_id"], [{"find": "nope", "replace": "x"}])


async def test_changes_made_outside_the_tools_still_get_a_card(fgw, store):
    artifacts = service(fgw, store)
    made = await artifacts.create("coder", "Plan", "text", "v1")
    ws = await phone(fgw, store)
    # As an agent did with its own code: a new version written straight into Lekora's store.
    store.add_artifact_version(made["artifact_id"], "v2", "agent", "edited directly")
    assert await artifacts.announce_outside_changes() == 1
    card_msg = None
    while card_msg is None:
        msg = await recv(ws, timeout=3)
        if msg["type"] == "chat.message" and msg["data"].get("artifact", {}).get("action") == "updated":
            card_msg = msg["data"]
    assert card_msg["artifact"]["version"] == 2, "the card comes to the newest message"
    assert await artifacts.announce_outside_changes() == 0, "only once"
    await ws.close()


async def test_cards_carry_a_preview_and_new_kinds(fgw, store):
    artifacts = service(fgw, store)
    ws = await phone(fgw, store)
    code = "\n".join(f"line {n}" for n in range(1, 40))
    await artifacts.create("coder", "Long", "code", code, language="python")
    card_msg = (await until(ws, "chat.message"))[0]["data"]["artifact"]
    assert card_msg["excerpt"].startswith("line 1\nline 2") and card_msg["excerpt"].count("\n") == 13, "the first lines"
    diagram = await artifacts.create("coder", "Flow", "diagram", "flowchart TD\n  A-->B")
    assert diagram["kind"] == "mermaid"
    app = await artifacts.create("coder", "Counter", "jsx", "export default function App() { return <b>1</b> }")
    assert app["kind"] == "react"
    page = await artifacts.create("coder", "Page", "html", "<p>x</p>")
    assert "excerpt" not in page, "pages are drawn on the phone"
    await ws.close()
