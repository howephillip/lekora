# Agents: choosing and switching (Phase 1)

Every Hermes profile on the host is an agent in the app, and all are equal.

## Host
- One Hermes gateway serves all profiles ("multiplexing"; Hermes turns it on automatically once a second profile exists). The single Lekora adapter in that gateway reaches every profile.
- `lekora/profiles.py` discovers the profiles live from the Hermes root on every `hello` and `chat.send`, using only Hermes' public plugin surface (`hermes_constants`). A profile created or deleted in Hermes shows up at the phone's next connect, with no restart.
- Routing: each phone message is stamped `source.profile = <profile_id>` and Hermes runs that turn as that profile; the reply comes back through `send(chat_id=<profile_id>)`. **No Hermes config is written** (no `gateway.profile_routes` entries). Unknown profiles are rejected with `UNKNOWN_PROFILE` before reaching Hermes, so a message never silently lands on another agent.
- `platforms.lekora.extra.profiles` can still pin a fixed list (e.g. to hide profiles from the phone).

## App
- **Choose Agents** (`ChooseProfilesView`): after pairing, when the host has more than one agent. All are preselected; at least one must stay on. Skipped automatically with one agent. Reopened any time from the chat's agent menu ("Choose Agents…").
- **Switcher**: tap the agent name at the top of the chat (system title menu). Lists the chosen agents with a checkmark on the current one. Switching shows that agent's own conversation and sends new messages to it.
- The choice and the current agent are stored with the pairing on the phone (Keychain) and cleared by Forget Host. They are per pairing, so a new phone or re-pair chooses again.
- Agents removed on the host are dropped from the choice at the next connect; if the current one is gone, the first remaining is used; if none remain, Choose Agents shows again. New agents are offered in Choose Agents but not switched on automatically.

## Not yet
- Creating and deleting agents from the phone (required by the project rules; separate feature).
- An agent added on the host while the phone is connected appears after the next reconnect.
- No unread indicator for replies that arrive for an agent you're not viewing.

## Tests
Plugin: `tests/test_profiles.py` (discovery, names and descriptions, deleted/parked/invalid skipped, live re-discovery, pinned list). App: `LekoraTests/AgentSwitchingTests.swift` against the fake host (choose, auto-choose single, order and persistence, switching routes `chat.send`, per-agent history, removed/new agents on the host, Forget Host clears the choice, optional description). Also checked once with the real app client against the real plugin service and three profiles.
