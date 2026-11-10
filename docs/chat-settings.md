# Per-chat settings (Phase 2, feature 6)

Tap the agent (avatar and name) at the top of a chat to open **Chat Settings**. It shows what the chat is running on and lets you change it without typing commands.

## What's on the screen
- **Summary:** the agent, the chat's name (tap to rename), and three tiles: model, how much of the model's memory (context) this chat uses, and its cost so far. Anything Hermes can't report shows "—".
- **This Session Only:** Model (opens the model picker), Reasoning (Off … Extra High), Fast Mode, **Auto-Approve**.
- **All of <agent>'s Chats:** Personality, Approvals (Ask Me / Smart / Never Ask), Show Reasoning. These are saved in that agent's Hermes settings; other agents keep their own.
- **Actions:** New Chat (asks first), Compress Conversation, Retry Last Message, Undo Last Turn (asks first). The sheet closes and Hermes answers in the chat.
- A value Hermes can't report (e.g. after a Hermes update changed it) shows as "Unknown"; the rest keep working.

## Auto-Approve (owner's decision, 2026-11-09: Option A)
- Turning it on asks first: "<agent> will run risky commands in this chat without asking you first…". Turning it off doesn't ask.
- Approvals → Never Ask asks first too.
- While either is on, the chat header shows a small amber **Auto** badge next to the model, and the settings summary shows an amber **Auto-approve** badge.

## How it works
- **Changes are Hermes' own commands**, handed to the agent's chat as if typed (`/reasoning high`, `/fast fast`, `/yolo`, `/personality pirate`, `/approvals smart`, `/reasoning show`, `/title …`, `/new`, `/compress`, `/undo`, `/retry`). Hermes applies and saves them its own way and replies in the chat (small grey line). The plugin never writes Hermes config for this (rule 8 untouched).
- `/yolo` is a toggle in Hermes, so the host only sends it when the state really changes.
- **Reading** uses Hermes internals (checked against Hermes 0.22.5; `plugin/lekora/hermes_settings.py`): the session's model override, reasoning and service-tier resolution, YOLO state, the profile's effective config (approvals, personality, display), the resident agent's usage stats and the session database row (title, cost). Each value is read on its own and becomes `null` if it fails.
- The app shows a change straight away, then re-reads the settings 1.5 s later (and whenever Hermes posts a system line in a chat whose settings are loaded). A refused change goes back to the old value and shows "Couldn't change that".
- Reasoning and fast mode for a session reset when Hermes restarts (Hermes' rule); the screen says so.

## Protocol
`protocol.md` §9: `settings.get`, `settings.set`, `settings.action`.

## Tests
- **Plugin** (`tests/test_chat_settings.py`): every change → command, YOLO only toggled on a real change, bad values refused (incl. unsafe personality names), gateway requests, reading every setting from stand-ins for Hermes, and one broken part reading as unknown while the rest still read.
- **App** (`ChatSettingsTests`): load from the fake host, Auto-Approve shows at once (and Approvals off also counts), a refused change keeps the old value, actions reach the host, all-unknown settings decode.
- **Simulator** against the real plugin with a stand-in Hermes: header model line, sheet contents, Auto-Approve warning, amber badges appear and disappear, reasoning/fast changes, compress.
