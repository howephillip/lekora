# Past chats (Phase 5 follow-up)

Owner's request (2026-11-15): when a new chat starts, the old one should fold away (still viewable, and restorable), so one agent can have many chats without the window filling up and slowing down.

- **What a chat is:** a Hermes conversation ("session"), as Hermes keeps them: it starts one on New Chat or `/new`, and on its own daily/idle reset, each with a title, start and end. Lekora doesn't invent its own.
- **Which chat a message belongs to:** every message saved from now on carries its Hermes conversation (`session`, read from Hermes' session store at the moment it's saved). Earlier messages are placed by time (the conversation that had started when they were saved).
- **In the chat:** only the current conversation is shown. Earlier ones fold into an **Earlier chats** pill at the top; scrolling up doesn't load them. After New Chat (or Hermes' own reset), the chat starts clean.
- **Past Chats** (the pill, or Chat Settings › Past Chats): each conversation with its Hermes title (or its first words), when, and how many messages; the current one marked. Open one to read it; **Continue This Chat** makes it the chat again with Hermes' own `/resume <id>`, and its messages come into the chat. Chats with nothing but Hermes' "new session" notice aren't listed.
- Nothing is written to Hermes; only its own commands are used.
- **Protocol:** `protocol.md` §19.
- **Tests:** plugin `test_chat_sessions.py` (tagged with the conversation, older ones by time, list/read/continue with Hermes' /resume, only the agent's own chats, live messages carry it, empty chats left out); app `PastChatsTests` (messages know their conversation, list/read/continue, a "new session" notice moves the chat on). Simulator (iOS 27.0, real plugin, stand-in Hermes with three conversations): only today's shown, Earlier chats, Past Chats list, read and continue, New Chat starts clean.

## Also (owner, 2026-11-15)
- **Artifacts live at the newest message:** each artifact's newest card is the full card; older cards of it shrink to a quiet line ("v1 · newer version below") that opens the newest.
- **Times on every message:** dragging the chat left shows the time beside voice notes, spoken replies, files, artifact cards and reviews too, not only text.
