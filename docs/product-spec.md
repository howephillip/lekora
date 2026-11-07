# Product spec

Targets: iOS 27 primary, iOS 26 minimum (degrade gracefully). Push notifications deferred; messages arrive while the app is open or recently open.

## Where we aim to lead
1. **Voice**: streaming speech as replies are written, scrubbable, per-agent voice style, hands-free mode.
2. **Artifacts**: agents create HTML/documents/code via a plugin tool; sandboxed rendering, versions, edit, share.
3. **File sharing both ways**: plugin tools for agent-to-user and user-to-agent; no prompt hacks.
4. **Kanban**: native view of the Hermes dashboard kanban.
5. **Scheduler**: full cron management (create, edit, pause, run now, history).
6. **Group chats**: user @-mentions agents; one shared context for all agents in the chat.
7. **Live gateway connection**: one persistent connection; agents can message first.

## Also included
Analytics (usage and spend) · model selection · multiple profiles (all equal, create/delete) · multiple Hermes instances · delegation and sub-agents (agents talking to each other, shown as a tree) · per-chat and per-agent settings (reasoning, length, temperature...) · live agent calling · skills (create, add, remove) · MCP (add, large curated library) · slash commands (many) · permission pop-ups (Approve once / always / this session / Deny) · native Tailscale support (detect, use tailnet addresses, deep-link).

## Setup wizard
Install plugin (one command) → discover/pair (code or QR) → verify → choose profiles → done. Re-run only on a major incompatibility, which the version handshake reports plainly.

## Build order
1. Foundation: protocol, pairing wizard, store, design system, test harness.
2. Complete chat: streaming, history, profiles, instances, model picker, per-chat settings, slash commands, permissions.
3. Files both ways.
4. Voice.
5. Artifacts.
6. Kanban and scheduler.
7. Delegation, then group chats.
8. Analytics, skills, MCP library, Tailscale polish, live calling.
