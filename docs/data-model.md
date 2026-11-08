# Data model (draft)

Every record is keyed by `instance_id` + `profile_id`.

- **Instance**: one Hermes install (id, display name, addresses, paired devices).
- **Profile**: Hermes profile; listed from Hermes, never owned by the app.
- **Conversation**: `direct` (one profile) or `group` (many profiles, one shared transcript, members, @-routing).
- **Message**: id, seq, role, parts (text, file, artifact, tool activity), status.
- **Settings**: app-level, per-profile, per-conversation (reasoning, length, temperature...). Fixed named fields with allowed values, validated.
- **Artifact**: id, versions, kind, content ref.
- **File**: id, direction, name, size, hash, store ref.
- **Usage**: per message/model tokens and cost, for analytics.

## Where it lives
Plugin store (SQLite in Hermes's data directory) is the source of truth. The app keeps a local cache and secrets (Keychain). Re-pairing a new phone restores everything from the plugin. Chat messages are stored by the plugin as numbered events (`lekora.db`), with read markers per agent; the phone caches them (see `chat-history.md`).
