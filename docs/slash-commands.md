# Slash commands (Phase 2, feature 4)

Type `/` in the message bar and the agent's commands appear above it, with a short description each. The list narrows as you type. Commands with fixed options (e.g. `/approvals manual · smart · off`) offer those options next. Sending works as before: the command goes to Hermes, which answers in the chat.

## Where the list comes from (Hermes 0.22.5)
From the same sources as Hermes' own Telegram and Discord menus, so it matches what Hermes accepts:
- **Built-in commands:** `hermes_cli.commands_platforms._gateway_available_commands()` (registry entries available on messaging platforms, including the user's config gates), with their localized description (`describe()`), argument hint (`args_hint`), aliases, category, and fixed options (`hermes_cli.commands.SUBCOMMANDS`).
- **Plugin and skill commands:** `_collect_gateway_skill_entries("lekora", …)`, which skips skills disabled for the platform. Plugin argument hints come from `get_plugin_commands()`.
- **The user's `quick_commands`** from `config.yaml` (described as "Runs: …" / "Same as …" when they have no description).

Skills, plugins and settings differ per agent, so the list is read inside that agent's Hermes home (`hermes_constants.set_hermes_home_override`), in a background thread. Each source is optional: if a Hermes update changes one, the others still show and the change is logged.

## When it's read
Every time a chat opens (and again once connected, if it opened offline). Hermes already rescans skills when they change, so the list is always current. The phone keeps the last list in memory.

## Protocol
See `protocol.md` §7.

## App
- `LKCommandMatcher`: commands whose name starts with what's typed come first, then alias matches, then names containing it.
  - After a space, it offers the command's fixed options.
  - Nothing shows for text that isn't a command, for a complete command that takes nothing, or for an already complete option.
- Tapping a suggestion fills the message bar: "/new", or "/model " with room for the argument. You send it.
- The list sits above the message bar on a glass panel, at most about 5 rows tall, and scrolls.

## Tests
- **Plugin:**
  - `commands.list` for an agent;
  - the same list gives the same fingerprint;
  - a failing reader gives an empty list;
  - an unknown agent is an error;
  - reading Hermes' sources with stand-in Hermes modules: all four sources, the agent's own home, a broken source not hiding the others, and duplicates left out.
- **App:** matching, aliases, options, inserting, and loading from the fake host.
- **Simulator** against the real plugin. **Real Hermes** on your machine.

## Known limits
- Options are shown only where Hermes lists fixed ones. `/model` takes free text; the model picker is the next feature.
- Commands an admin limited in Hermes' Lekora settings (`allow_admin_from` / `user_allowed_commands`) still appear; Hermes refuses them when sent, as it does for typed commands.
