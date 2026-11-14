# Agent tools in Lekora chats

Owner's report (2026-11-12): agents in Lekora chats said they lacked tools they had before (the task board in particular).

## Why
Lekora chats are their own Hermes platform, `lekora`. Hermes resolves each platform's tools from `platform_toolsets.<platform>` in the agent's `config.yaml`; with nothing saved for `lekora`, it uses the plugin-platform default bundle (Hermes' core tools), which leaves out **default-off** toolsets such as `kanban` and `x_search`. An agent's choices for Telegram, the CLI or the API server don't carry over to a new platform.

## What the app does
- Chat Settings › **Tools in Lekora Chats**: every Hermes toolset (built in and plugin ones), on or off for this agent's Lekora chats, as Hermes resolves them (read back from Hermes, not guessed). **Same as Telegram** (or any other platform with a saved list) copies that list.
- A change runs Hermes' own command, `hermes -p <agent> tools enable|disable <toolsets> --platform lekora`, which writes only Lekora's own platform entry (`platform_toolsets.lekora` and Hermes' bookkeeping for it). The agent's `config.yaml` is backed up first to `<Hermes>/lekora-backups/config/<agent>/` (rule 8); no backup, no change. Afterwards the tools are read back from Hermes and anything that didn't apply is reported.
- Nothing else is written; no other platform's tools are touched.

## About the "api_server toolset provisioning" brief (2026-11-12)
That brief attributes `platform_toolsets.api_server` / `known_builtin_toolsets.api_server` writes on the owner's Pi to Lekora. Lekora's code never writes those keys:
- Lekora connects to Hermes as the `lekora` messaging platform, not through the API server.
- Its only config write before this feature was the model picker's OpenRouter routing (`provider_routing.models."<model>"`, docs/model-picker.md). That write reads the file exactly as written (`read_user_config_raw`), changes only `provider_routing`, and writes everything else back as it was; it can't add `api_server` keys. The `lekora-backups/config/<agent>/` copies the brief found are the backups it makes before that write, which is why they exist only for agents whose routing was saved.
- To check on the Pi: `grep -n api_server ~/.hermes/lekora-backups/config/brenda/config.yaml.original` — if the keys are already there, they predate Lekora's first write. The API server is used by other Hermes apps and the dashboard.
- The brief's findings on what those keys do are right, and its repair (enabling `kanban` for `api_server`) is fine for whatever uses the API server; it doesn't affect Lekora chats, which this feature covers.

## Protocol
`protocol.md` §14.

## Tests
`plugin/tests/test_agent_tools.py`: changes go through Hermes after a backup and only for the `lekora` platform; nothing to change writes nothing; a change that didn't stick is reported; unknown toolsets and failed backups change nothing; the requests over the connection. App: `HearingRepliesTests` (tools get and set).

## Fix (owner, 2026-11-13): tools for every agent
Tools couldn't be turned on for any agent but the default one. Hermes' `hermes -p <agent> tools …` command only knows the "lekora" platform in profiles where the Lekora plugin is switched on, which is only the default profile (it answered "Unknown platform 'lekora'"). The plugin now saves with Hermes' own tools code instead (the same save that command makes: `platform_toolsets.lekora` in that agent's `config.yaml`, after the same backup), which works for every agent (rule 5). Checked on the owner's Pi against a copy of Carl's settings.
