# Helpers: delegation shown as a tree (Phase 7, feature 1)

## What the user sees
- When an agent hands parts of a job to **helpers** (Hermes' own subagents, `delegate_task`), a **Helpers card** appears in that agent's chat. One card per reply that used helpers.
- The card is a tree: each helper is a row with what it was asked to do, what it is doing right now ("Searching the web"), how many steps it has taken and for how long. A helper that itself uses helpers has its own branch, indented under it.
- Each row ends as **Done**, **Failed**, **Stopped** or **Timed out**. Tap a row to read the helper's full task and what it reported back.
- **Stop** on a working row stops that helper; **Stop all** on the card stops every helper still working. Hermes stops them at their next step and the agent gets what they had so far.
- **Asking another agent.** Agents get a Lekora tool, `lekora_ask_agent`, to hand a task to another of the user's agents (owner, 2026-11-19). That agent works in the background *as itself* (its own personality, model, tools and settings), shows in the tree as a branch with its name, and reports back to the agent that asked. Its own chat is untouched. Every agent can ask every other agent (rule 5).
- The card updates live, survives reconnects and app restarts (it is a saved chat item), and is the same on every paired phone. Helpers left working when Hermes restarts show as **Stopped**.

## How it works (plugin)
- Hermes' official plugin hooks, nothing written to Hermes config:
  - `subagent_start` (helper id, its parent helper, goal, parent session) creates the row. A first-level helper's chat comes from the Lekora session it was started in; a nested helper joins its parent's tree.
  - `post_tool_call` with a helper's id (`sa-…`) counts a step and sets "doing now".
  - `subagent_stop` (matched by the helper's session) sets the ending, the report and the duration. Hermes fires it when the whole batch ends, so while a helper is out of Hermes' list of running helpers but not yet reported, it shows **Finishing**.
  - Once a second, while a tree is working, Hermes' list of running helpers refreshes "doing now" and the step count.
- Updates to a card are sent at most once a second.
- Stop uses Hermes' own `interrupt_subagent(helper id)`.
- **Asking another agent:** Lekora registers a Hermes delegation backend, `lekora`, that runs a task as a named profile (Hermes' own profile routes: that profile's config, model, credentials, skills and SOUL). `lekora_ask_agent(agent, task, context?)` switches *only the calling session* to that backend for the one call (Hermes' per-session switch, in memory), calls Hermes' `delegate_task` with the agent named, then switches back. A first-level ask runs in the background like any helper; the answer comes back to the asking agent as a new turn. Asking itself or an unknown agent is refused with the list of agents.

## Protocol
- A Helpers card is a `chat.message` with `role: "helpers"` and a `delegation` object (docs/protocol.md §22). It is updated in place: same `seq`, new `rev`.
- `delegation.stop {seq, helper_id?}` → `delegation.stop.result {stopped: [ids]}`. No `helper_id` stops every working helper on that card.

## Limits
- Live progress comes from Hermes' hooks and its running-helper list; Hermes' per-step text and token counts are not shown.
- Helpers started by schedules or other apps are not shown (only Lekora chats).
- If the user picked another delegation backend in Hermes, ordinary helpers keep using it; only `lekora_ask_agent` uses Lekora's.
