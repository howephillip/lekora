"""A pretend Hermes for README screenshots and demos. No real Hermes, no personal data.

Runs the real Lekora plugin with made-up agents and scripted replies, on 127.0.0.1.
Start:  plugin/.venv/bin/python tools/demo_host.py     (prints a pairing link)
In a chat, type: "approve" (an approval card), "ask" (a question card),
"/model" (model picker), anything else (a streamed reply).
"""
import asyncio, io, sys, tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "plugin"))
from lekora.pairing import run_pair
from lekora.plugin import LekoraConfig, LekoraService

PROFILES = [
    {"profile_id": "default", "name": "Default", "avatar": "sparkles"},
    {"profile_id": "scout", "name": "Scout", "avatar": "sparkles"},
    {"profile_id": "juniper", "name": "Juniper", "avatar": "sparkles"},
    {"profile_id": "atlas", "name": "Atlas", "avatar": "sparkles"},
]
SEED = {
    "default": [("user", "What's on my plate today?"),
                ("assistant", "Three things: the invoice review at 10, a call with Dana at 2, and the draft you wanted to finish. Want me to block time for the draft?")],
    "scout": [("user", "Find me a quiet cafe near the office with good wifi."),
              ("assistant", "Found two: **Fernwood Coffee** (8 min walk, power outlets at every table) and **The Quiet Cup** (12 min, no music before noon).")],
    "juniper": [("user", "Can you summarise the meeting notes?"),
                ("assistant", "Done. Main decisions: ship the beta on Friday, move the review to Tuesday, and Priya owns the launch checklist.")],
    "atlas": [("user", "Plan a weekend trip to the coast."),
              ("assistant", "Here's a relaxed plan: leave Saturday at 9, lunch in Port Ellis, a sunset walk on the pier, and a slow Sunday before heading home.")],
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
REPLY = ("Sure! Here's a quick plan:\n\n1. Gather the details you mentioned\n2. Draft a first version\n"
         "3. Check it with you before anything is sent\n\nI'll start now and keep you posted.")


class Demo:
    svc = None

    async def deliver_to_agent(self, profile_id, text, message_id):
        gw = self.svc.gateway
        t = text.strip().lower()
        if t == "approve":
            await self.svc.prompts.ask_approval(profile_id, "demo", "rm -rf ~/Downloads/old-installers",
                "Deletes files from your Downloads folder", ["once", "session", "always", "deny"])
        elif t == "ask":
            await self.svc.prompts.ask_question(profile_id, "demo", "Which day works best for the trip?",
                ["Saturday", "Sunday", "Both"], "demo-q")
        elif t == "/model":
            async def chosen(*a, **k): return "ok"
            await self.svc.prompts.ask_model(profile_id, "demo", [
                {"slug": "anthropic", "name": "Anthropic", "is_current": True, "models": ["claude-sonnet-5-5", "claude-opus-5-5", "claude-haiku-5-5"]},
                {"slug": "openrouter", "name": "OpenRouter", "models": ["deepseek/deepseek-v4", "google/gemini-3-pro", "meta/llama-5"]},
            ], "claude-sonnet-5-5", "anthropic", chosen)
        else:
            await gw.publish_typing(profile_id, True, "Searching the web…")
            await asyncio.sleep(1.2)
            words = REPLY.split(" ")
            for i in range(1, len(words) + 1):
                await gw.publish_draft(profile_id, "d1", " ".join(words[:i]))
                await asyncio.sleep(0.12)
            await gw.publish_typing(profile_id, False)
            await gw.publish_message(profile_id, REPLY, draft_id="d1")


async def main():
    tmp = Path(tempfile.mkdtemp(prefix="lekora-demo-"))
    demo = Demo()
    cfg = LekoraConfig(db_path=str(tmp / "lekora.db"), listen_host="127.0.0.1",
                       instance_name="Demo Hermes", extra_hosts=["127.0.0.1"], profiles=PROFILES)
    svc = LekoraService(demo, cfg, hermes_version="0.22.5",
                        commands_provider=lambda pid: COMMANDS)
    demo.svc = svc
    await svc.start()
    for pid, msgs in SEED.items():
        for role, text in msgs:
            svc.store.append_event(pid, "chat.message", {"role": role, "text": text})
    out = io.StringIO()
    run_pair(svc.store, out, extra_hosts=["127.0.0.1"], listening=lambda p: True)
    print(out.getvalue(), flush=True)
    await asyncio.Event().wait()

asyncio.run(main())
