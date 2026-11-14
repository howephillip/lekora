# AGENTS.md

The owner is not a developer: explain outcomes, not mechanics. Lead reports with the verdict. Update `STATUS.md` before finishing.

## Non-negotiables

1. The app is a layer on top of any existing Hermes instance. Hermes is never forced to expose an API; the plugin connects natively (as a messaging platform).
2. The plugin install is the only technical setup the user does. Everything else happens in the app's setup wizard, run once.
3. App data (chats, settings, artifacts, analytics) survives re-setup or a new phone. Truth lives in the plugin's store on the Hermes machine; the phone is a cache.
4. Hardware-agnostic: no assumptions about machine, OS, addresses, ports, or profile names. Personal specifics are settings with defaults.
5. All profiles are equal. No "main agent". Every feature works for every profile, including create and delete.
6. Every record carries `instance_id` and `profile_id` from day one.
7. Agents get real tools from the plugin (send file, create artifact, request approval). Never inject behaviour by prompting every message.
   - Exception (owner, 2026-11-12): Personality Voice. Only while a chat's voice replies use Personality Voice, the plugin passes Hermes' own per-turn chat instruction (`MessageEvent.channel_prompt`, part of the system prompt, never the user's message) telling the agent its reply will be spoken and how to sound (personality and cadence the user chose). Nothing is added in any other mode, and no reply is rewritten behind the agent's back.
   - Exception (owner, 2026-11-13): hands-free calls. Only for words said in a call, the plugin passes the same per-turn chat instruction saying it's a live voice call: a transcript, a spoken reply (short, plain sentences), and to hand longer work to a background task and keep talking (modelled on Hermes' own note for its live voice conversations). Nothing is added outside a call.
8. The plugin only writes to a clearly labelled app-owned section of Hermes config, backs up first, and confirms before any delete.
   - Exception (owner, 2026-11-09): OpenRouter routing for a model. When the user saves a routing choice in the model picker, the plugin writes only `provider_routing.models."<model id>"` in that agent's `config.yaml`, through Hermes' own config writer. It backs up to `<Hermes>/lekora-backups/config/<agent>/` first, keeping the original (pre-Lekora) copy forever plus the 10 newest, and tells the user what changed.
9. Ask before: spending money, sending anything external, adding a dependency that needs an account.
10. Push notifications and Watch are out of scope for now.

## Definition of done (per feature)

A feature is done only when all hold: short spec in `docs/`; protocol messages defined; plugin half built; app half built; automated tests (fake Hermes, plus real-Hermes pass); and the owner has confirmed it on a real phone. No half-done states in `STATUS.md`. Finish one feature before starting the next.
