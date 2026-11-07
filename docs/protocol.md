# Protocol (draft)

One persistent WebSocket between app and plugin. Messages are JSON envelopes.

```
{ "v": 1, "id": "<uuid>", "type": "<name>", "instance_id": "...", "profile_id": "...", "ts": "<iso8601>", "data": { } }
```

## Rules
- **Versioning:** on connect the app sends its supported range; the plugin replies with the chosen version or `incompatible` with a plain-language reason. Compatible across a window of versions.
- **Ordering and replay:** every server event has a monotonically increasing `seq` per instance. On reconnect the app sends `last_seq` and the plugin replays what was missed.
- **Acks:** client commands are acknowledged by `id`; commands are idempotent.
- **Auth:** pairing produces a per-device key stored in the Keychain; revocable from the plugin.
- **Ports/addresses:** the plugin chooses a free port and advertises it during pairing. Nothing is hard-coded.

## Message families (to be specified one by one as each feature starts)
`hello/pair`, `chat.*` (send, delta, final, tool activity), `profile.*`, `settings.*`, `model.*`, `approval.*`, `file.*`, `artifact.*`, `voice.*`, `kanban.*`, `cron.*`, `group.*`, `delegation.*`, `skill.*`, `mcp.*`, `analytics.*`, `slash.*`.

Each family gets its own section here before any code is written for it.
