# Lekora's tools for every agent: the `lekora` command (owner, 2026-11-22)

## Why
Hermes only gives a plugin's tools to the agent the plugin runs in (the instance's launch profile).
Every other agent never had Lekora's artifact and file tools (Phase 7 limit). Agents already have
Hermes' own terminal tool, so Lekora gives them a command to run instead.

## What the user sees
- Every agent can make **artifacts** (cards), change and read them, and **send files**, in one-to-one
  and group chats. In a group, every member can work on the same artifacts.
- Chat Settings › Tools › **Artifacts and Files** shows that the agent has them. Turning it off turns
  Lekora's skill off for that agent.
- Skills page: **lekora-tools**, "From Lekora", in the "lekora" category. It can be turned on or off,
  but not edited or removed, because Lekora keeps it up to date.

## How it works (plugin)
- **The command** (`agent_command.py`, standard library only). Lekora writes a small launcher,
  `<Lekora data folder>/lekora-command/lekora` (`lekora.cmd` on Windows). The launcher points at the
  plugin's own script and Python. Commands:
  - `artifact create`, `update`, `edit`, `read`, `list`;
  - `send-file`.
  Each prints the same JSON the matching tool returns.
- **Which chat.** Hermes passes every command the chat it came from (`HERMES_SESSION_PLATFORM`,
  `HERMES_SESSION_CHAT_ID`), group-member chats included. Outside a Lekora chat, the command says so
  and does nothing.
- **Reaching Lekora** (`agent_bridge.py`). The running Lekora listens on 127.0.0.1, on a free port.
  - Each start, it writes the port and a fresh token to `lekora-command/bridge.json`, readable only by
    this user.
  - A request runs exactly what the tool runs, in that chat, with the same code (`artifacts.call_tool`,
    `hermes_files.send_file_async`).
  - Wrong tokens and unknown tools are refused.
- **How agents learn it: Lekora's skill.** At each start, and as new agents appear, Lekora writes
  `<agent home>/skills/lekora/lekora-tools/SKILL.md`, with a `.lekora-managed` marker. The skill
  explains the commands with this machine's command path.
  - Hermes lists it in the agent's skill index like any other skill.
  - Nothing is added to the user's messages (rule 7).
  - The agent's config is never written (rule 8). On/off is the Skills switch.
  - A skill of that name that Lekora didn't make is left alone.
- Agents that do have Lekora's real tools are told by the skill to use those.

## Protocol
- `agent.tools.get` / `agent.tools.set` results add `lekora_skill: on|off|missing`.
- Skills `source` can be `lekora`. Removing or editing it gives `INVALID_REQUEST`.

## Limits
- Needs the agent's terminal to run on the Hermes machine, which is Hermes' default `local` backend.
  A container or remote terminal can't reach 127.0.0.1 on the Hermes machine.
- Works while the agent is answering in a Lekora chat. Board workers and scheduled jobs have no
  Lekora chat.
