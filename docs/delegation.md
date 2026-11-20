# Delegation shown as a tree (Phase 7, feature 1)

## What the user sees
- When an agent delegates from a Lekora chat, a **Delegated** card ("<agent> delegated") appears in that chat. Two kinds of delegation, one card:
  - **Handing work to another agent** (owner, 2026-11-19: the common way agents delegate to each other in Hermes). The agent gives a task to another agent on Hermes' board (`kanban_create` with an assignee, e.g. Assistant → Researcher). The row shows who has it, the task, and where it's at: **Waiting to start**, working (what's happening now, e.g. "Picked up by researcher"), **Blocked** (with Hermes' reason), **Done**, or **Stopped** (archived). If that agent hands part of it on (Researcher → Coder), it branches under it.
  - **Sub-agents**: copies of the agent Hermes' `delegate_task` makes. They show as "Sub-agent", with what each is doing, steps and time.
- Tap a row for the whole task and what came back, **Open in Board** (board tasks) and **Stop** (a running board task's worker, as the Board's Stop; or a working sub-agent). **Stop All** when more than one can be stopped.
- **The chat is never blocked (owner, 2026-11-19).** The card only shows. The agent stays free to talk while the work runs; results reach it the way Hermes already delivers them (board updates and sub-agent results wake the agent), and it tells the user in the chat.
- Handoffs from one chat within two minutes share a card. The card updates live, is the same on every phone, and survives reconnects and app restarts (a saved chat item). After a Hermes restart, board tasks are followed again (they live on in Hermes); sub-agents that were working show **Stopped**.

## How it works (plugin)
- **Board handoffs**, from the board itself (every 3 seconds): a new task whose origin is one of the agent's Lekora conversations (`session_id`, `created_by`) goes to that agent's chat; a task whose creator is a followed task (`creator_task_id` in its `created` event) goes under it. Followed tasks are re-read each time (status, assignee, last history line, result). The `post_tool_call` hook also catches a `kanban_create` from a Lekora chat the moment it happens. Tasks made elsewhere (terminal, other apps) aren't shown.
- **Sub-agents**, from Hermes' official hooks: `subagent_start` (row), `post_tool_call` with a sub-agent's id (`sa-…`: a step, and "doing now"), `subagent_stop` (ending, report, duration; Hermes fires it when the batch ends, so in between a sub-agent shows **Finishing**). Hermes' running list refreshes them every second while any work.
- Card updates are sent at most once a second. Nothing is written to Hermes config and no tools are added: Lekora only watches.

## Results reach the agent (fix, 2026-11-19)
- Hermes hands finished background work (sub-agent results, process completions) back to the agent as a new turn only when the chat's saved origin (the sender of its first message, kept through every New Chat) matches the sender of the user's messages. Lekora chats saved before the user chose a name (and the default agent's, tagged with a profile its messages never carry) failed that check (`admission_conflict`), so results were retried and then dropped, and the agent never heard them.
- Lekora now keeps each chat's origin in step with what it sends (the user's name; the agent's profile, none for the default agent): at start, before every message, and when the user's name changes. Hermes internals (`SessionStore` entry origin): re-check after Hermes upgrades.

## Protocol
- A Delegated card is a `chat.message` with `role: "delegation"` and a `delegation` object (docs/protocol.md §22), updated in place (same `seq`, new `rev`).
- `delegation.stop {seq, helper_id?}` → `delegation.stop.result {stopped: [ids]}`.

## Limits
- Board rows show Hermes' last history line ("Picked up by researcher", "Blocked: …"), not the worker's every step.
- A sub-agent's per-step text and token counts are not shown.
