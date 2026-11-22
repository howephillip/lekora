"""Skills: each agent's Hermes skills from the phone (docs/skills.md)."""

import json
from pathlib import Path

import pytest

from lekora.routing_config import RoutingConfig
from lekora.skills import SkillError, Skills, frontmatter
from tests.test_gateway import env, gw, recv  # noqa: F401  (gw fixture)
from tests.test_history import drain, hello_rev


def skill(root: Path, rel: str, name: str, desc: str, body: str = "Do the thing."):
    folder = root / rel
    folder.mkdir(parents=True)
    (folder / "SKILL.md").write_text(f"---\nname: {name}\ndescription: \"{desc}\"\n---\n\n{body}\n")


@pytest.fixture
def home(tmp_path):
    root = tmp_path / "hermes"
    sk = root / "skills"
    skill(sk, "apple/apple-reminders", "apple-reminders", "Apple Reminders via remindctl")
    skill(sk, "hermes-agent", "hermes-agent", "How Hermes works")
    skill(sk, "research/arxiv", "arxiv", "Search arXiv papers")
    skill(sk, "golf", "golf", "My golf notes")
    skill(sk, "golf/references", "not-a-skill", "inside a support folder")
    (sk / ".bundled_manifest").write_text("apple-reminders:abc\nhermes-agent:def\n")
    (sk / ".hub").mkdir()
    (sk / ".hub" / "lock.json").write_text(json.dumps({"version": 1, "installed": {"arxiv": {"trust_level": "trusted"}}}))
    (root / "config.yaml").write_text(json.dumps({"model": "x", "skills": {"disabled": ["golf"]}}))
    return root


class Cli:
    def __init__(self, home):
        self.home, self.calls, self.fail = home, [], False

    async def __call__(self, args):
        self.calls.append(list(args))
        if self.fail:
            return 1, "Installation blocked: dangerous verdict\n"
        if args[:2] == ["skills", "search"]:
            return 0, "Searching…\n" + json.dumps([{"name": "pdf", "identifier": "official/pdf", "source": "official",
                                                    "trust_level": "builtin", "description": "Read PDFs"}])
        if args[2:4] == ["skills", "install"]:
            skill(self.home / "skills", "docs/pdf", "pdf", "Read PDFs")
            return 0, "Installed pdf\n"
        if args[2:4] == ["skills", "uninstall"]:
            import shutil
            shutil.rmtree(self.home / "skills" / "research" / "arxiv")
            return 0, "Uninstalled arxiv\n"
        return 1, "?"


def read(path):
    return json.loads(Path(path).read_text()) if Path(path).is_file() else {}


def write(path, data):
    Path(path).write_text(json.dumps(data))


@pytest.fixture
def cli(home):
    return Cli(home)


@pytest.fixture
def skills(home, cli, tmp_path):
    async def llm(instructions, text):
        return {"name": "Weekly Review!", "description": "Sum up my week every Friday",
                "category": "productivity", "instructions": "1. Read the calendar.\n2. Summarise."}
    return Skills(profiles=lambda: ["default"], home_of=lambda p: home, read_config=read, write_config=write,
                  backup_config=RoutingConfig(home / "lekora-backups" / "config").backup, run_cli=cli,
                  backups=home / "lekora-backups", scan=lambda ident: {"name": "pdf", "verdict": "safe", "policy": "allow"},
                  llm=llm)


def test_the_list_shows_where_each_came_from_and_whether_its_on(skills):
    got = {s["name"]: s for s in skills.list("default")}
    assert set(got) == {"apple-reminders", "hermes-agent", "arxiv", "golf"}  # support folders aren't skills
    assert got["apple-reminders"]["source"] == "builtin" and got["apple-reminders"]["category"] == "apple"
    assert got["arxiv"]["source"] == "hub" and got["arxiv"]["trust"] == "trusted"
    assert got["golf"]["source"] == "local" and got["golf"]["enabled"] is False
    assert got["hermes-agent"]["essential"] is True


def test_turning_one_off_backs_up_and_changes_only_the_disabled_list(skills, home):
    skills.set_enabled("default", "arxiv", False)
    cfg = read(home / "config.yaml")
    assert cfg == {"model": "x", "skills": {"disabled": ["golf", "arxiv"]}}
    assert (home / "lekora-backups" / "config" / "default" / "config.yaml.original").is_file()
    assert skills.set_enabled("default", "golf", True)["enabled"] is True
    assert read(home / "config.yaml")["skills"]["disabled"] == ["arxiv"]


def test_hermes_own_skill_stays_on(skills):
    with pytest.raises(SkillError):
        skills.set_enabled("default", "hermes-agent", False)


async def test_search_scan_install_and_remove(skills, cli, home):
    found = await skills.search("pdf reader")
    assert found == [{"name": "pdf", "identifier": "official/pdf", "source": "official", "trust_level": "builtin",
                      "description": "Read PDFs"}]
    assert (await skills.scan("official/pdf"))["policy"] == "allow"
    installed = await skills.install("default", "official/pdf")
    assert installed["name"] == "pdf" and cli.calls[-1] == ["-p", "default", "skills", "install", "official/pdf", "--yes"]
    assert await skills.remove("default", "arxiv") == {"name": "arxiv"}  # a catalog skill: Hermes uninstalls it
    assert cli.calls[-1] == ["-p", "default", "skills", "uninstall", "arxiv", "--yes"]


async def test_a_refused_install_says_why(skills, cli):
    cli.fail = True
    with pytest.raises(SkillError) as err:
        await skills.install("default", "community/bad")
    assert err.value.code == "INSTALL_REFUSED" and "blocked" in err.value.reason


async def test_removing_a_skill_made_here_keeps_a_backup(skills, home):
    got = await skills.remove("default", "golf")
    assert not (home / "skills" / "golf").exists() and (Path(got["backup"]) / "SKILL.md").is_file()


async def test_describe_draft_then_save(skills, home):
    draft = await skills.draft("A weekly review every Friday")
    assert draft["name"] == "weekly-review" and draft["category"] == "productivity"
    assert frontmatter(draft["content"])["description"] == "Sum up my week every Friday"
    made = skills.save("default", draft["content"], create=True, category=draft["category"])
    assert made["source"] == "local" and (home / "skills" / "productivity" / "weekly-review" / "SKILL.md").is_file()
    with pytest.raises(SkillError) as err:
        skills.save("default", draft["content"], create=True)
    assert err.value.code == "SKILL_EXISTS"


def test_editing_keeps_the_previous_version(skills, home):
    new = "---\nname: golf\ndescription: Golf notes v2\n---\n\nBetter.\n"
    skills.save("default", new, create=False, name="golf")
    assert skills.get("default", "golf")["content"] == new
    kept = list((home / "lekora-backups" / "skills" / "default").glob("golf-*.SKILL.md"))
    assert kept and "My golf notes" in kept[0].read_text()


@pytest.mark.parametrize("content,reason", [
    ("no header", "header"), ("---\nname: Bad Name\ndescription: x\n---\n", "lowercase"),
    ("---\nname: ok\ndescription: " + "x" * 61 + "\n---\n", "60")])
def test_hermes_rules_for_a_skill(content, reason):
    with pytest.raises(SkillError) as err:
        Skills.check(content)
    assert reason in err.value.reason


async def test_the_phone_lists_and_toggles(gw, store, skills):
    gw.skills = skills
    device_id, tok = store.register_device("iPhone")
    ws = await hello_rev(gw, store, device_id, tok, since_rev=store.current_rev())
    await recv(ws)
    await ws.send(env(store, "skills.list", {}, profile_id="default", msg_id="s1"))
    got = [m for m in await drain(ws) if m.get("id") == "s1"][0]
    assert got["type"] == "skills.list.result" and len(got["data"]["skills"]) == 4
    await ws.send(env(store, "skill.enable", {"name": "arxiv", "enabled": False}, profile_id="default", msg_id="s2"))
    got = [m for m in await drain(ws) if m.get("id") == "s2"][0]
    assert got["data"]["skill"]["enabled"] is False
    await ws.send(env(store, "skills.list", {}, profile_id="nobody", msg_id="s3"))
    err = [m for m in await drain(ws) if m.get("id") == "s3"][0]
    assert err["data"]["code"] == "UNKNOWN_PROFILE"
