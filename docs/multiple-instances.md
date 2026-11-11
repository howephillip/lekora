# Multiple Hermes instances (Phase 2, feature 7)

One app, several Hermes instances (e.g. one on a Pi, one on a Mac). The app calls them Hermes instances, not computers (owner, 2026-11-10). Each instance runs the plugin and is paired once; the app keeps a separate, encrypted connection to each, so one being off doesn't affect the others.

## What you see
- **Hermes Instances** ("…" → Hermes Instances…): every paired instance with a dot and "Connected · 3 agents" / "Not connected" / "Connecting…". **Add Hermes Instance** opens the usual pairing (QR or link) as a sheet with Cancel, then Choose Agents if the instance has more than one.
- **An instance's page:** its name and **Rename…** (only while connected), its status with Try Again, and **Forget This Instance** (asks first; removes only that instance from the phone, after asking it to remove this phone from its device list; its chats stay on the instance).
- **Agents list:** every agent from every instance.
  - **Sort by Recent** (default): one list, newest conversation first. Once there are two or more instances, each row shows the instance's name in small grey text after the agent's name ("Default · omacron").
  - **Group by Instance**: one section per instance, headed by its name and (when not connected) its status; no grey names on the rows.
  - The choice is in the "…" menu, shown once there are two or more instances. It's kept on the phone.
- **Add Agent (+)**: with several instances, asks which instance ("Add an Agent On").
- **Manage Agents**: with several instances, a submenu per instance.
- **Chat header**: with several instances, the instance's name sits under the agent's name. The back button's unread count includes the other instances' agents.
- **Avatars**: agents keep their look; colours on a later instance avoid the ones already used, so two "Default" agents differ.

## The instance's name (owner's decision 2026-11-10: renamable)
- Shown name: the one chosen in the app, else the plugin setting `instance_name`, else its machine's network name (e.g. "omacron"; before, unnamed instances were all "Hermes").
- Renaming saves it **on the instance** (plugin store), so every phone and a new phone see it. Other connected phones update straight away.

## How it works
- **Phone:** one `GatewayClient` per instance (its own connection, cache file `chat-<instance id>.json`, unread, drafts, settings), held by `HostsModel`. Agents are identified by `(instance_id, profile_id)`.
- **Saved pairings:** keychain keys `host.<instance id>.<field>`, plus `hosts` listing them in pairing order. A pairing from before (plain keys) moves over automatically on first launch; nothing to redo.
- **Pairing an instance that's already paired** replaces its old pairing.
- **Messages for another instance** (wrong `instance_id`) are ignored.
- **Reconnects:** each instance on its own, 1.5 s after a dropped connection; an unreachable one is retried every 20 s while the agents list is showing, and all of them when the app comes back to the front.
- Across instances the list is ordered by message time (each instance's change numbers are its own).

## Protocol
`protocol.md` §10: `instance.rename`, `instance.changed`.

## Tests
- **Plugin** (`tests/test_instances.py`): default name is the machine's name; the app's name wins over the plugin setting across restarts; rename reaches every phone; bad names refused; new phones get the name.
- **App** (`MultipleInstancesTests`): old pairing moves over; forgetting one keeps the other; both connect with two "default" agents kept apart (messages, colours, sending); newest first across instances; one offline doesn't stop the other; other instances' messages ignored; pairing a second keeps the first; re-pairing replaces; rename and rename from another phone; the instance's name wins on connect; forgetting one instance.
- **Simulator** with the real plugin, two stand-in instances: migration from the old pairing, Add Hermes Instance (with and without choosing agents), rename, both layouts, instance tags and headers, sending to one instance only, Add Agent menu, relaunch reconnecting both.
