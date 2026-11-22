"""A pretend Hermes for README screenshots and demos. No real Hermes, no personal data.

Runs the real Lekora plugin with made-up agents and scripted replies, on 127.0.0.1.
Start:  plugin/.venv/bin/python tools/demo_host.py     (prints a pairing link)
In a chat, type: "approve" (an approval card), "ask" (a question card),
"/model" (model picker), anything else (a streamed reply).
"""
import asyncio, io, os, sys, tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "plugin"))
from lekora.pairing import run_pair
from lekora.plugin import LekoraConfig, LekoraService
from lekora.prompts import Resolvers

PROFILES = [
    {"profile_id": "default", "name": "Default", "avatar": "sparkles"},
    {"profile_id": "scout", "name": "Scout", "avatar": "sparkles"},
    {"profile_id": "juniper", "name": "Juniper", "avatar": "sparkles"},
    {"profile_id": "atlas", "name": "Atlas", "avatar": "sparkles"},
]
SEED = {
    "default": [("user", "Good morning! What's on my plate today?"),
                ("assistant", "Morning! Three things today:\n\n1. **10:00** invoice review with Priya\n2. **14:00** call with Dana about the launch\n3. The **draft announcement** you wanted to finish\n\nWant me to block time for the draft?"),
                ("user", "Yes please, after lunch.")],
    "scout": [("user", "Find me a quiet cafe near the office with good wifi."),
              ("assistant", "Found two:\n\n- **Fernwood Coffee**: 8 min walk, power outlets at every table\n- **The Quiet Cup**: 12 min walk, no music before noon\n\nFernwood is the better bet for a long work session.")],
    "juniper": [("user", "Can you summarise the meeting notes from Monday?"),
                ("assistant", "Done. Main decisions: ship the beta on **Friday**, move the design review to **Tuesday**, and Priya owns the launch checklist. I added the open questions to the board.")],
    "atlas": [("user", "I'd love a relaxed weekend by the coast. Can you help plan it?"),
              ("assistant", "Absolutely. Do you want something active (hikes, kayaking) or slow (cafes, long walks)? And roughly how far are you happy to drive?")],
}
COMMANDS = [
    {"name": "new", "description": "Start a new conversation", "args": "", "choices": [], "aliases": ["reset"], "group": "hermes"},
    {"name": "model", "description": "Show or change the model", "args": "[model]", "choices": [], "aliases": [], "group": "hermes"},
    {"name": "reasoning", "description": "Set how hard the agent thinks", "args": "[level]", "choices": ["low", "medium", "high"], "aliases": [], "group": "hermes"},
    {"name": "fast", "description": "Toggle fast mode", "args": "", "choices": ["on", "off"], "aliases": [], "group": "hermes"},
    {"name": "approvals", "description": "Choose how approvals work", "args": "[mode]", "choices": ["manual", "smart", "off"], "aliases": [], "group": "hermes"},
    {"name": "summarize", "description": "Summarise a page or file", "args": "<url>", "choices": [], "aliases": [], "group": "skill"},
    {"name": "research", "description": "Dig into a topic and report back", "args": "<topic>", "choices": [], "aliases": [], "group": "skill"},
]

ITINERARY_HTML = """<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
<style>body{font-family:-apple-system,system-ui,sans-serif;margin:0;background:#f4f7fb;color:#1d2733}
header{background:linear-gradient(135deg,#2f80ed,#56ccf2);color:#fff;padding:28px 20px}
h1{margin:0 0 4px;font-size:26px}p.sub{margin:0;opacity:.9}
main{padding:16px}.day{background:#fff;border-radius:16px;padding:16px;margin-bottom:14px;box-shadow:0 2px 8px rgba(0,0,0,.06)}
.day h2{margin:0 0 10px;font-size:18px}.row{display:flex;gap:12px;padding:8px 0;border-top:1px solid #eef1f5}
.row:first-of-type{border-top:0}.t{width:56px;color:#2f80ed;font-weight:600}</style></head><body>
<header><h1>Coast weekend</h1><p class="sub">Port Ellis · Sat 9 – Sun 6</p></header><main>
<div class="day"><h2>Saturday</h2>
<div class="row"><span class="t">9:00</span><span>Leave home, scenic coast road</span></div>
<div class="row"><span class="t">12:30</span><span>Lunch at The Salt House (fish tacos)</span></div>
<div class="row"><span class="t">15:00</span><span>Cliff walk to Lantern Point, 5 km</span></div>
<div class="row"><span class="t">19:00</span><span>Sunset on the pier, dinner nearby</span></div></div>
<div class="day"><h2>Sunday</h2>
<div class="row"><span class="t">10:00</span><span>Slow breakfast at Harbour Bakery</span></div>
<div class="row"><span class="t">11:30</span><span>Kayak rental, calm bay (2 hrs)</span></div>
<div class="row"><span class="t">15:00</span><span>Drive home, ice cream stop</span></div></div>
</main></body></html>"""


def _settings_state():
    return {
        "model": {"model": "claude-sonnet-5-5", "provider": "anthropic", "this_chat": False},
        "reasoning": {"effort": "medium", "this_chat": False},
        "show_reasoning": False, "fast": "normal", "yolo": False,
        "personality": {"current": "none", "options": [
            {"name": "concise", "description": "Short, direct answers with no filler."},
            {"name": "friendly", "description": "Warm and encouraging, like a helpful friend."},
            {"name": "coach", "description": "Motivating and practical; asks good questions."},
            {"name": "pirate", "description": "Answers like a swashbuckling pirate."}]},
        "approvals": "manual", "title": None,
        "usage": {"input_tokens": 18420, "output_tokens": 2310, "total_tokens": 20730,
                  "context_tokens": 20730, "context_length": 200000, "cost_usd": 0.083},
    }


def _model_info(provider, model):
    prices = {"claude-sonnet-5-5": (3.0, 15.0, 200000), "claude-opus-5-5": (15.0, 75.0, 200000),
              "claude-haiku-5-5": (0.8, 4.0, 200000)}
    if model not in prices:
        return None
    i, o, c = prices[model]
    return {"input": i, "output": o, "context": c, "reasoning": True, "vision": True, "tools": True}


def _openrouter_picks():
    """A few real OpenRouter models for the picker, from their public list (offline: a fallback)."""
    import json, urllib.request
    fallback = ["anthropic/claude-sonnet-4.5", "google/gemini-2.5-pro", "deepseek/deepseek-chat-v3.1"]
    try:
        with urllib.request.urlopen("https://openrouter.ai/api/v1/models", timeout=10) as r:
            ids = [m["id"] for m in json.load(r)["data"]]
    except Exception:
        return fallback
    picks = []
    for prefix in ("anthropic/", "openai/", "google/", "deepseek/", "meta-llama/"):
        found = [i for i in ids if i.startswith(prefix) and ":" not in i]
        if found:
            picks.append(found[0])
    return picks or fallback


async def _stream(gw, pid, text, status=None, delay=0.05, lead=0.8):
    await gw.publish_typing(pid, True, status)
    await asyncio.sleep(lead)
    words = text.split(" ")
    draft = "d" + os.urandom(4).hex()
    for i in range(1, len(words) + 1):
        await gw.publish_draft(pid, draft, " ".join(words[:i]))
        await asyncio.sleep(delay)
    await gw.publish_typing(pid, False)
    await gw.publish_message(pid, text, draft_id=draft)


TOOLSETS = [("web", "Web search", "Search the web and read pages"),
            ("terminal", "Terminal", "Run commands on the Hermes computer"),
            ("file", "Files", "Read, write and organise files"),
            ("kanban", "Task board", "Create and manage tasks on the board"),
            ("tts", "Speech", "Speak replies aloud"),
            ("x_search", "X search", "Search posts on X")]
_enabled = {}


def tools_read(profile):
    on = _enabled.setdefault(profile, {"web", "terminal", "file", "kanban"})
    return {"toolsets": [{"key": k, "label": l, "description": d, "enabled": k in on} for k, l, d in TOOLSETS],
            "elsewhere": {"telegram": ["kanban", "terminal", "web", "x_search"]}}


def tools_write(profile, enable, disable):
    on = _enabled.setdefault(profile, {"web", "terminal", "file", "kanban"})
    on.update(enable)
    on.difference_update(disable)


_demo_configs: dict = {}  # agents' config.yaml, in memory (the demo has no Hermes config writer)


def seed_demo_skills(root):
    """A few made-up skills for the Skills screen (docs/skills.md)."""
    import json as _json
    skills = root / "skills"
    if (skills / ".bundled_manifest").exists():
        return
    for rel, name, desc in (("productivity/calendar-digest", "calendar-digest", "Sum up the day's calendar"),
                            ("research/web-brief", "web-brief", "Short researched briefs with sources"),
                            ("hermes-agent", "hermes-agent", "How Hermes works"),
                            ("travel/coast-weekend", "coast-weekend", "Plan a slow weekend by the coast")):
        folder = skills / rel
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "SKILL.md").write_text(f"---\nname: {name}\ndescription: \"{desc}\"\n---\n\n## When to use\n\n{desc}.\n\n## Steps\n\n1. Gather what's needed.\n2. Write it up.\n")
    (skills / ".bundled_manifest").write_text("hermes-agent:x\nweb-brief:y\n")


async def demo_cli(args):
    """Hermes' CLI as the demo needs it: a skills catalog search."""
    import json as _json
    if list(args[:2]) == ["skills", "search"]:
        return 0, _json.dumps([{"name": "pdf", "identifier": "skills-sh/anthropics/skills/pdf", "source": "skills.sh",
                                "trust_level": "trusted", "description": "Read, fill and merge PDF files"},
                               {"name": "spreadsheet-helper", "identifier": "clawhub/someone/spreadsheet-helper",
                                "source": "clawhub", "trust_level": "community", "description": "Tidy up spreadsheets"}])
    return 1, "Not available in the demo"


def demo_scan(identifier):
    community = "clawhub" in identifier
    return {"name": identifier.rsplit("/", 1)[-1], "identifier": identifier, "source": "demo",
            "trust_level": "community" if community else "trusted",
            "verdict": "caution" if community else "safe",
            "summary": "Runs a shell command from its script." if community else "No issues found.",
            "policy": "ask" if community else "allow", "policy_reason": None,
            "findings": [{"severity": "high", "category": "execution", "file": "scripts/run.sh", "line": 4,
                          "description": "Runs a downloaded script"}] if community else []}


async def demo_skill_llm(instructions, text):
    return {"name": "weekly-review", "description": "Sum up my week every Friday", "category": "productivity",
            "instructions": "## When to use\n\nOn Fridays, or when asked for a weekly review.\n\n## Steps\n\n1. Read this week's calendar.\n2. List what got done and what slipped.\n3. Suggest three priorities for next week."}


class DemoAnalytics:
    """Made-up usage for the Analytics screen (docs/analytics.md)."""
    PER_AGENT = {"default": 0.9, "scout": 0.4, "juniper": 2.6, "atlas": 0.25}

    def read_usage(self, profile, since):
        import datetime as dt, random
        rnd = random.Random(profile)
        start = dt.date.fromtimestamp(since)
        days = (dt.date.today() - start).days + 1
        scale = self.PER_AGENT.get(profile, 0.1)
        main, background = [], []
        for i in range(days):
            day = (start + dt.timedelta(days=i)).isoformat()
            for source, share in (("lekora", 0.5), ("cron", 0.2), ("kanban", 0.3)):
                cost = round(scale * share * rnd.uniform(0.3, 1.6), 4)
                main.append({"day": day, "source": source, "sessions": rnd.randint(1, 9), "cost_usd": cost, "tokens": int(cost * 900_000)})
            background.append({"day": day, "cost_usd": round(scale * 0.05, 4), "tokens": 20_000})
        total = sum(r["cost_usd"] for r in main)
        model = "anthropic/claude-sonnet-5.5" if profile == "juniper" else "deepseek/deepseek-v4.1-flash"
        return {"main": main, "background": background,
                "models": [{"model": model, "provider": "openrouter", "cost_usd": total * 0.9, "tokens": int(total * 800_000)},
                           {"model": "anthropic/claude-haiku-5.5", "provider": "openrouter", "cost_usd": total * 0.1, "tokens": int(total * 90_000)}]}

    def accounts(self, pairs):
        return [{"provider": "openrouter", "title": "Account limits",
                 "windows": [{"label": "API key quota", "used_percent": 17.1, "detail": "$82.87 of $100.00 remaining • resets monthly"}],
                 "details": ["Credits balance: $8.81", "API key usage: $106.19 total • $0.06 today • $3.24 this week • $17.13 this month"],
                 "agents": sorted({p for p, _ in pairs})}]

    def configured_provider(self, profile):
        return "openrouter"


class Demo:
    svc = None
    state: dict = {}
    asking = "default"

    def settings_for(self, pid):
        return self.state.setdefault(pid, _settings_state())

    async def deliver_to_agent(self, profile_id, text, message_id, files=None, instructions=None, spoken=False):
        gw = self.svc.gateway
        if profile_id.startswith("g."):
            return await self._group_turn(profile_id, text)
        raw = text.strip()
        t = raw.lower()
        st = self.settings_for(profile_id)
        if raw.startswith("/"):
            return await self._command(profile_id, raw, st)
        self.asking = profile_id
        if "download" in t:
            await _stream(gw, profile_id, "On it. I found **14 old installers** in ~/Downloads, about 2.3 GB, all older than 90 days. "
                          "I'll remove that folder now.", "Reading ~/Downloads…")
            await self.svc.prompts.ask_approval(profile_id, "demo", "rm -rf ~/Downloads/old-installers",
                "Deletes 14 files (2.3 GB) from your Downloads folder", ["once", "session", "always", "deny"])
        elif "coast" in t or "trip" in t or "active" in t or "slow" in t:
            await _stream(gw, profile_id, "Slow it is. I'll plan around cafes, an easy cliff walk and a sunset on the pier. "
                          "One question before I lock it in:", "Searching the web…")
            await self.svc.prompts.ask_question(profile_id, "demo", "Which day would you like the kayak outing on?",
                                                ["Saturday", "Sunday", "Skip kayaking"], "demo-q")
        elif "itinerary" in t or "page" in t:
            await _stream(gw, profile_id, "Here's the plan as a page you can keep and edit:", "Writing the itinerary…")
            await gw.artifacts.create(profile_id, "Coast weekend itinerary", "html", ITINERARY_HTML)
        else:
            await _stream(gw, profile_id, "Sure, I'm on it. I'll gather what I need, draft a first version, and "
                          "check with you before anything is sent.", "Thinking…")

    async def _group_turn(self, chat, text):
        """A member's turn in a group chat (docs/group-chats.md): a short scripted reply."""
        member = chat.rsplit(".", 1)[-1]
        newest = text.strip().split("\n")[-1].lower()
        lines = {
            "scout": "I can look for places along the coast: quiet cafes, a good bakery and somewhere to park.",
            "juniper": "I'll keep the notes: dates, budget and who's bringing what. @atlas, can you draft the plan?",
            "atlas": "Here's a first idea: Saturday cliff walk and the pier at sunset, Sunday slow breakfast and home by four.",
            "default": "I'll put it in your calendar once you're happy with the plan.",
        }
        if "@atlas" in newest and member != "atlas" and "can you draft" not in newest:
            reply = "(pass)"
        else:
            reply = lines.get(member, "Sounds good to me.")
        await asyncio.sleep({"scout": 0.3, "juniper": 0.9, "atlas": 1.5}.get(member, 0.6))
        await _stream(self.svc.gateway, chat, reply, "Thinking…", lead=0.4)

    def follow_up(self, pid, text, status=None):
        asyncio.get_running_loop().create_task(_stream(self.svc.gateway, pid, text, status, lead=1.0))

    def resolvers(self):
        demo = self

        def approve(session_key, choice, reason):
            pid = demo.asking
            if choice == "deny":
                demo.follow_up(pid, "Understood, I left your Downloads folder as it is. Tell me if you'd like me to try a smaller clean-up instead.")
            else:
                demo.follow_up(pid, "Done. I removed the 14 installers and freed **2.3 GB**. Your laptop now has 11.4 GB free.", "Running the command…")
            return 1

        def answer(clarify_id, text):
            demo.follow_up(demo.asking, f"{text} it is. I'll book the kayaks for then and add the plan to your calendar. "
                           "I've also put the full itinerary on a page for you to keep.", "Booking…")
            asyncio.get_running_loop().create_task(demo._itinerary(demo.asking))
            return True

        async def confirm(session_key, confirm_id, choice):
            return True, "New conversation started."
        return Resolvers(approve=approve, answer=answer, approval_timeout=lambda: 300, confirm=confirm)

    async def _itinerary(self, pid):
        await asyncio.sleep(9)
        await self.svc.gateway.artifacts.create(pid, "Coast weekend itinerary", "html", ITINERARY_HTML)

    async def _command(self, pid, raw, st):
        gw = self.svc.gateway
        cmd, _, arg = raw[1:].partition(" ")
        arg = arg.strip()
        if cmd == "model" and not arg:
            async def chosen(*a, **k): return "ok"
            await self.svc.prompts.ask_model(pid, "demo", [
                {"slug": "anthropic", "name": "Anthropic", "is_current": True,
                 "models": ["claude-sonnet-5-5", "claude-opus-5-5", "claude-haiku-5-5"]},
                {"slug": "openrouter", "name": "OpenRouter", "models": _openrouter_picks()},
            ], st["model"]["model"], st["model"]["provider"], chosen)
            return
        if cmd == "reasoning" and arg:
            st["reasoning"] = {"effort": "none" if arg == "off" else arg, "this_chat": True}
        elif cmd == "fast":
            st["fast"] = "fast" if arg in ("fast", "on", "") and st["fast"] != "fast" else "normal"
        elif cmd == "approvals" and arg:
            st["approvals"] = arg
        elif cmd == "personality" and arg:
            st["personality"]["current"] = arg
        elif cmd == "title" and arg:
            st["title"] = arg
        elif cmd == "yolo":
            st["yolo"] = not st["yolo"]
        elif cmd == "new":
            await self.svc.prompts.ask_confirm(pid, "demo", "Start a new conversation?",
                                               "This ends the current chat. Earlier chats stay in Past Chats.", "demo-c")
            return
        await gw.publish_message(pid, "Done.", role="system")


def demo_board():
    """A made-up board (docs/kanban.md), in memory, shaped like Hermes' own."""
    import time
    sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "plugin"))
    from tests.test_kanban import FakeBoards

    class DemoBoards(FakeBoards):
        def workflow(self):
            keys = ["triage", "todo", "scheduled", "ready", "running", "blocked", "review", "done"]
            moves = {"triage": ["todo", "ready"], "todo": ["triage", "scheduled", "ready"],
                     "scheduled": ["triage", "todo", "ready"], "ready": ["triage", "todo", "scheduled", "blocked", "review", "done"],
                     "running": ["triage", "todo", "ready", "blocked", "review", "done"],
                     "blocked": ["triage", "todo", "ready", "done"], "review": ["triage", "todo", "ready", "done"],
                     "done": ["triage", "todo", "ready"], "archived": ["triage", "todo", "ready"]}
            for k in keys:
                moves[k] = moves[k] + ["archived"]
            return [{"key": k, "label": k.capitalize()} for k in keys], moves

        def card(self, board, task_id):
            t = super().card(board, task_id)
            t.setdefault("created_at", time.time() - 3600)
            return t

        def comment(self, board, task_id, body, author):
            self._require(task_id)
            self.comments.setdefault(task_id, []).append(
                {"id": len(self.comments.get(task_id, [])) + 1, "author": author, "body": body, "created_at": time.time()})
            self._touch(task_id)
            return self.card(board, task_id)

        def task(self, board, task_id):
            got = super().task(board, task_id)
            got["parents"] = [{"id": p, "title": self.tasks_[p]["title"], "status": self.tasks_[p]["status"]}
                              for p, c in self.links if c == task_id]
            got["children"] = [{"id": c, "title": self.tasks_[c]["title"], "status": self.tasks_[c]["status"]}
                               for p, c in self.links if p == task_id]
            now = time.time()
            got["runs"] = [{"id": 1, "profile": got["task"].get("assignee") or "default", "status": "done",
                            "outcome": "completed", "started_at": now - 5400, "ended_at": now - 4800,
                            "summary": "Collected the numbers and drafted an outline.", "error": None}] \
                if got["task"]["status"] in ("done", "review", "running") else []
            got["events"] = [{"id": 1, "kind": "created", "created_at": now - 7200, "summary": "Created"}]
            return got

    b = DemoBoards()
    now = time.time()
    for title, status, who, pri, summary in [
            ("Book the venue for the launch party", "running", "scout", 2, "Called three places; waiting on one quote."),
            ("Draft the beta announcement", "ready", "juniper", 1, None),
            ("Review the Q3 invoices", "blocked", "default", 3, "Needs the October statement."),
            ("Plan the coast weekend", "todo", "atlas", 0, None),
            ("Sort the inbox newsletters", "triage", None, 0, None),
            ("Summarise the meeting notes", "done", "juniper", 0, "Ship beta Friday; review moved to Tuesday."),
            ("Find a quiet cafe near the office", "done", "scout", 0, "Fernwood Coffee, 8 min walk.")]:
        card = b.create("default", title=title, body=None, assignee=who, priority=pri, parents=[], triage=False, author="demo")
        t = b.tasks_[card["id"]]
        t.update(status=status, summary=summary, created_at=now - 86400)
        if status == "running":
            t["running_since"] = now - 1500
        if status == "done":
            t["completed_at"] = now - 3600
    b.links.add(("t_3", "t_2"))
    return b


async def main():
    keep = os.environ.get("DEMO_DATA")
    tmp = Path(keep) if keep else Path(tempfile.mkdtemp(prefix="lekora-demo-"))
    tmp.mkdir(parents=True, exist_ok=True)
    demo = Demo()
    cfg = LekoraConfig(db_path=str(tmp / "lekora.db"), listen_host="127.0.0.1",
                       instance_name="Demo Hermes", extra_hosts=["127.0.0.1"], profiles=PROFILES,
                       hermes_root=str(tmp / "hermes"))
    svc = LekoraService(demo, cfg, hermes_version="0.22.5",
                        commands_provider=lambda pid: COMMANDS, kanban_boards=demo_board(),
                        settings_reader=lambda pid: demo.settings_for(pid), model_info=_model_info,
                        resolvers=demo.resolvers(), tools_reader=tools_read, tools_writer=tools_write,
                        hermes_analytics=DemoAnalytics(), run_cli=demo_cli,
                        skills_scan=demo_scan, skill_llm=demo_skill_llm,
                        config_io=(lambda path: _demo_configs.get(str(path), {}),
                                   lambda path, data: _demo_configs.__setitem__(str(path), data)))
    demo.svc = svc
    seed_demo_skills(tmp / "hermes")
    await svc.start()
    # OpenRouter routing choices are kept in memory here (a real host writes the agent's Hermes config).
    from lekora.routing_config import RoutingConfig
    saved = {}
    svc.gateway.models.routing = RoutingConfig(tmp / "backups", read=lambda path: saved.get(str(path), {}),
                                               write=lambda path, data: saved.__setitem__(str(path), data))
    if not svc.store.list_groups():  # a group chat to try (docs/group-chats.md)
        await svc.gateway.groups.create("Weekend trip", ["scout", "juniper", "atlas"])
    if not svc.store.fetch_events_since(0):  # a fresh store: seed the opening conversations
        for pid, msgs in SEED.items():
            for role, text in msgs:
                svc.store.append_event(pid, "chat.message", {"role": role, "text": text})
    out = io.StringIO()
    run_pair(svc.store, out, extra_hosts=["127.0.0.1"], listening=lambda p: True)
    print(out.getvalue(), flush=True)
    await asyncio.Event().wait()

asyncio.run(main())
