# Chat screen (Phase 1)

The screen shown once the app is connected. Replaces the walking-skeleton "Send Ping" button.

## Behaviour
- Header: instance name, active profile ("Active Agent"), connection dot (green = connected), current seq.
- Messages for the active profile in arrival order. The user's on the right (blue), the agent's on the left. The list follows the newest message, including when the keyboard opens.
- Bottom bar: multi-line text field (up to 5 lines) and a Send button. Empty or whitespace-only text can't be sent.
- A sent message appears immediately, dimmed with "Sending…" until the socket accepts it. If sending fails, or the host returns an `error` with that message's `id` (e.g. `UNKNOWN_PROFILE`, `AGENT_ERROR`), it shows "Not delivered: <reason>".
- Disconnect is in the top-right toolbar.

## Protocol
No new messages. Uses `chat.send` and `chat.message` from `protocol.md`, plus `error` matched by envelope `id`.
- The host doesn't echo a `chat.send` to the phone that sent it, so the app adds it locally.
- On replay the host may resend that message as `chat.message` with `role: "user"`. The app matches it to the local copy (same profile and text, no seq yet) instead of showing it twice, and ignores any seq it already has.
- Active profile is the first profile from `hello.ack` (no profile picker yet).

## Not yet
- Chat history isn't stored on the phone between launches, and the app doesn't reconnect by itself on launch.
- No typing indicator (the host doesn't send one yet).

## Tests
`app/LekoraTests/ChatTimelineTests.swift`: ordering, replay de-duplication, repeated seq, messages from other devices, failure marking, per-profile separation, `chat.send` wire format, and host-frame handling.
