# Permission pop-ups and question cards (Phase 2, feature 3)

When an agent wants to do something risky, Hermes stops and asks. When an agent needs you to choose, Hermes asks a question. Lekora shows both as cards in the chat, with buttons. Tap one and the agent carries on.

## How Hermes asks (verified in Hermes 0.22.5's code)
- **Approvals.** A risky terminal command, `execute_code`, SSH-config write, computer use, or a plugin rule makes Hermes pause the agent.
  - It calls the platform's `send_exec_approval(...)`, which renders an `ExecApprovalPrompt`: the (redacted) command, why it was flagged, and the allowed choices `once` / `session` / `always` / `deny`.
  - A platform that overrides `_send_exec_approval_prompt` gets this button hook; all others get a plain-text "reply `/approve` or `/deny`" message. Telegram, Discord and Slack use the hook.
  - The answer goes to `tools.approval.resolve_gateway_approval(session_key, choice, reason=…)`. It resolves the oldest waiting approval of that chat.
  - Nobody answers within `approvals.timeout` (default 5 minutes): nothing runs. Hermes then edits the card (`edit_message`) into a "timed out" notice.
  - `always` adds the command's pattern to that agent's permanent allowlist in Hermes. That is Hermes' own setting, written by Hermes at the user's request; Lekora writes nothing.
- **Questions** (the `clarify` tool). Hermes calls `send_clarify(chat_id, question, choices, clarify_id, session_key, metadata)` once per question, with up to 4 choices, or none for an open question.
  - A button answer goes to `tools.clarify_gateway.resolve_gateway_clarify(clarify_id, text)`: the chosen option's text, a JSON list of texts for multi-select, or your own typed answer.
  - When a question ends without a button (timeout, reset, a typed reply), Hermes calls `retire_clarify_card(clarify_id, notice)`.
  - Typing an answer in the chat still works, through Hermes' own text matching.

## What you see
- **Approval card,** in the chat where the agent is working:
  - "Bruce wants to run a command" with the command in a code box, and why it was flagged.
  - **Allow** (primary, runs it once) and **Deny**.
  - **More** opens "Allow for this chat" (this command type, for the rest of this conversation) and "Always allow". Always allow first asks for confirmation, because it permanently adds the command to the agent's allowed list on your Hermes computer.
  - **Deny** lets you add an optional reason, which the agent sees.
  - A countdown ("4:32 left"). When it runs out: "Timed out — nothing ran".
  - After answering, the card shows the result ("Allowed once", "Allowed for this chat", "Always allowed", "Denied") and the buttons go away.
  - When Hermes' safety check itself advised against the command, the card says so and offers only Allow once / Deny (Hermes' rule).
- **Question card:**
  - The agent's question, with a button per option, plus **Other…** to type your own answer.
  - With several allowed, you tick options, then **Send**.
  - An open question has an answer field.
  - After answering, it shows your answer.
- **Elsewhere in the app:**
  - The agent's row on the home screen says **Needs your approval** (orange) or **Has a question**.
  - Cards count as unread, so they show in the dots and the back-button badge.
  - Nothing is lost if you're in another chat.
- **On every phone:** cards are saved in the chat on the Hermes computer, so they survive restarts and show on every paired phone. Answering on one phone updates the others.
- **A card that can't be answered any more** shows why instead of buttons:
  - it timed out,
  - it was answered by typing in the chat,
  - the agent's turn ended,
  - or the Hermes computer restarted.

## Host (`lekora/prompts.py`, adapter)
- **Approvals:** the adapter overrides `_send_exec_approval_prompt`. `Prompts.ask_approval(chat_id, session_key, prompt)` saves the card as a chat event (role `approval`) and returns `card-<id>` as the message id. That is how Hermes' timeout edit reaches it.
- **Questions:** the adapter overrides `send_clarify` and `retire_clarify_card`. `Prompts.ask_question(...)` saves a card (role `question`) and remembers `clarify_id`.
- **An answer from the phone** (`prompt.respond`):
  - The host checks the card is still pending and was asked in this run of Hermes.
  - It resolves through Hermes' own functions, and updates the card (a new change number, so every phone gets it).
  - Hermes reporting nothing pending means the card is marked expired.
- **Closing cards:**
  - The timeout edit: the approval timed out.
  - `retire_clarify_card`: the question closed.
  - The turn ends (`on_processing_complete`): any card still pending in that chat is closed ("No longer needed").
  - A typed `/approve` or `/deny` in the chat: pending approvals are "Answered in chat".
  - Any other typed message: pending questions are "Answered in chat".
  - On startup: cards left pending from a previous run are marked expired, since Hermes forgot them.
- **Labels:** the phone shows its own button labels. The host sends the choices Hermes allows.

## Protocol
See `protocol.md` §6.

## Tests
- **Plugin (pytest, fake Hermes resolvers):**
  - cards saved and broadcast, with the choices Hermes allows,
  - approve / deny (with reason) / session / always passed to the resolver,
  - multi-select and "Other" answers,
  - a resolver reporting nothing pending marks the card expired,
  - timeout edit, retire, turn end, typed `/approve`, typed reply,
  - startup expiry,
  - unknown card,
  - double answers,
  - other phones updated.
- **Real Hermes code (on this Mac, without touching its config):** the adapter is recognised as button-capable (`supports_exec_approval_buttons()`), and the prompt, resolve and clarify functions it calls exist with the expected signatures.
- **App (`swift test`, fake host):**
  - cards decode and render state,
  - tapping sends `prompt.respond`,
  - updates from another phone,
  - countdown expiry,
  - the list row shows "Needs your approval",
  - cards survive the cache.
- **Simulator** against the real plugin. **Real Hermes pass** on your Hermes machine: ask an agent to run something risky (e.g. delete a temp folder).

## Known limits
- Hermes resolves the oldest pending approval of a chat, whichever card you tap. With two approvals waiting in one chat (parallel tools), answering one card may answer the other one first. Hermes' own Telegram/Slack buttons behave the same way. Each card shows the result Hermes actually applied.
- Push notifications for approvals are out of scope (rule 10): open the app to answer.
