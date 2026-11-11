# Multiple Hermes computers (Phase 2, feature 7)

One app, several Hermes computers (e.g. a Pi and a Mac). Each computer runs the plugin and is paired once; the app keeps a separate, encrypted connection to each, so one being off doesn't affect the others.

## What you see
- **Computers** ("…" → Computers…): every paired computer with a dot and "Connected · 3 agents" / "Not connected" / "Connecting…". **Add Computer** opens the usual pairing (QR or link) as a sheet with Cancel, then Choose Agents if the computer has more than one.
- **A computer's page:** its name and **Rename…** (only while connected), its status with Try Again, and **Forget This Computer** (asks first; removes only that computer from the phone, after asking it to remove this phone from its device list; its chats stay on the computer).
- **Agents list:** every agent from every computer.
  - **Sort by Recent** (default): one list, newest conversation first. Once there are two or more computers, each row shows the computer's name in small grey text after the agent's name ("Default · omacron").
  - **Group by Computer**: one section per computer, headed by its name and (when not connected) its status; no grey names on the rows.
  - The choice is in the "…" menu, shown once there are two or more computers. It's kept on the phone.
- **Add Agent (+)**: with several computers, asks which computer ("Add an Agent On").
- **Manage Agents**: with several computers, a submenu per computer.
- **Chat header**: with several computers, the computer's name sits under the agent's name. The back button's unread count includes the other computers' agents.
- **Avatars**: agents keep their look; colours on a later computer avoid the ones already used, so two "Default" agents differ.

## The computer's name (owner's decision 2026-11-10: renamable)
- Shown name: the one chosen in the app, else the plugin setting `instance_name`, else the machine's own network name (e.g. "omacron"; before, unnamed computers were all "Hermes").
- Renaming saves it **on the computer** (plugin store), so every phone and a new phone see it. Other connected phones update straight away.

## How it works
- **Phone:** one `GatewayClient` per computer (its own connection, cache file `chat-<instance id>.json`, unread, drafts, settings), held by `HostsModel`. Agents are identified by `(instance_id, profile_id)`.
- **Saved pairings:** keychain keys `host.<instance id>.<field>`, plus `hosts` listing them in pairing order. A pairing from before (plain keys) moves over automatically on first launch; nothing to redo.
- **Pairing a computer that's already paired** replaces its old pairing.
- **Messages for another computer** (wrong `instance_id`) are ignored.
- **Reconnects:** each computer on its own, 1.5 s after a dropped connection; an unreachable one is retried every 20 s while the agents list is showing, and all of them when the app comes back to the front.
- Across computers the list is ordered by message time (each computer's change numbers are its own).

## Protocol
`protocol.md` §10: `instance.rename`, `instance.changed`.

## Tests
- **Plugin** (`tests/test_computers.py`): default name is the machine's name; the app's name wins over the plugin setting across restarts; rename reaches every phone; bad names refused; new phones get the name.
- **App** (`MultipleComputersTests`): old pairing moves over; forgetting one keeps the other; both connect with two "default" agents kept apart (messages, colours, sending); newest first across computers; one offline doesn't stop the other; other computers' messages ignored; pairing a second keeps the first; re-pairing replaces; rename and rename from another phone; the computer's name wins on connect; forgetting one computer.
- **Simulator** with the real plugin, two stand-in computers: migration from the old pairing, Add Computer (with and without choosing agents), rename, both layouts, computer tags and headers, sending to one computer only, Add Agent menu, relaunch reconnecting both.
