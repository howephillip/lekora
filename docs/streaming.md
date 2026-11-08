# Streaming replies (Phase 2, feature 1)

Replies appear word by word while the agent writes. A "thinking…" line shows while it works, with what it's doing when Hermes says ("Searching the web…").

## How Hermes streams (verified in Hermes 0.22.5's code)
Hermes streams by **editing**:
- It `send`s the first words with `metadata.expect_edits`, then calls `edit_message` with the **full text so far** plus a cursor (`" ▉"`), several times a second.
- `edit_message(..., finalize=True)` marks a message **sealed**. That happens at the end of the reply and at every tool boundary; the next text then starts a new message.
- While the agent works, Hermes calls `send_typing` about every 2 s, then `stop_typing`. With `supports_status_text`, it keeps a phrase like "Searching the web for …" for the chat.
- `on_processing_complete` signals the end of the turn.

Streaming needs Hermes' global `streaming.enabled` switch, which is off by default, and per-platform settings can only narrow it. Editing Hermes' config breaks rule 8 and asking the user to run a command breaks rule 2. So `lekora/hermes_streaming.py` turns it on **for Lekora only, in memory**:
- Lekora registers a private marker as its own `streaming` display default.
- The plugin wraps the running gateway's in-memory streaming config so that `enabled_for(marker)` is true, unless the user set `streaming.transport: off`.
- Every other platform gets the user's real setting, and nothing is written to Hermes' config.
- If a Hermes update changes these internals, the plugin logs it once and replies arrive whole, as before.

Lekora also registers `tool_progress: off`, so tool activity shows in the working line instead of as extra chat messages.

## Host (`lekora/streaming.py`, adapter)
| Hermes calls | Lekora does |
|---|---|
| `send(expect_edits)` | opens a live reply and sends `chat.draft` (not stored) |
| `edit_message` | updates the draft: full text, cursor removed |
| `edit_message(finalize=True)` | **saves** the text as `chat.message`, carrying `draft_id` so the phone swaps it in place |
| an edit of an already-saved message | updates the saved event in place and resends `chat.message` with the same `seq` (replays carry the new text) |
| `on_processing_complete` | saves any live reply never sealed (what the phone showed is kept), then sends `chat.typing` inactive |
| `send` without `expect_edits` | saved immediately, as before |
| `send_typing` / `stop_typing` | sends `chat.typing` active (with status) or inactive (not stored) |

The adapter declares `SUPPORTS_MESSAGE_EDITING`, `REQUIRES_EDIT_FINALIZE`, `MAX_MESSAGE_LENGTH = 100000` (long replies stay one bubble) and `supports_status_text`.

## Protocol (host → phone, not stored, not replayed)
```json
{ "type": "chat.draft",  "profile_id": "bruce", "data": { "draft_id": "live-1a2b…", "text": "full text so far" } }
{ "type": "chat.typing", "profile_id": "bruce", "data": { "active": true, "status": "Searching the web" } }
{ "type": "chat.message","profile_id": "bruce", "data": { "seq": 42, "role": "assistant", "text": "…", "draft_id": "live-1a2b…" } }
```
- `chat.draft` with empty `text` drops the bubble.
- `chat.message` with a `seq` the phone already has replaces that message's text (an agent correction).

## Phone
- **Live bubble:** grows with a cursor, and is replaced in place by the saved message (same bubble, no flicker). The view follows the newest words.
- **Thinking line:**
  - shows animated dots, plus the status when there is one;
  - is hidden while the reply itself is streaming, unless there's a status, such as a tool running between messages;
  - clears on `chat.typing` inactive, or after 6 s without a ping.
- **Edge cases:**
  - Each agent has its own live bubble and thinking state.
  - After a reconnect, unfinished live bubbles are dropped, because the host's replay is the truth.

## Tests
- Plugin, `tests/test_streaming.py`:
  - send, edits, seal, corrections and segments
  - an unsealed reply saved at turn end; an empty reply dropped
  - cursor stripping
  - the Lekora-only switch (others unchanged, user's global setting respected, `transport: off` respected, fallbacks)
- Plugin, `tests/test_gateway.py`: drafts and typing reach every phone and are never stored; corrections are resent and replayed.
- App, `LekoraTests/StreamingTests.swift`:
  - draft lifecycle, late and empty drafts
  - corrections, per-agent bubbles
  - drop after reconnect
  - activity per agent and its timeout
  - end-to-end with the fake host
- Also checked once with the real app (TLS, pinned) against the real plugin driven like Hermes' stream consumer.

## Not yet
- Reasoning text isn't streamed; Hermes only adds it to the final message, if enabled.
- Tool output isn't shown in the chat.
