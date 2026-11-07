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

---

## 1. `hello/pair` (Pairing & Connection Handshake)

Pairing is managed entirely by the plugin. It works whether the phone is on the local network, remote, or on Tailscale, without requiring a hard network lock or static IP.

### Step 1: Pairing Invitation
Upon plugin installation/startup, the plugin starts its WebSocket listener on a dynamically selected port and prints an invite URI (and terminal QR code):
```
lekora-pair://pair?token=<one_time_token>&instance_id=<instance_id>&endpoints=<url_encoded_csv>
```
Endpoints include all detected routes:
- Local LAN (e.g. `ws://192.168.1.50:48123`)
- Tailscale (e.g. `ws://hermes-host.tailnet.ts.net:48123` if Tailscale is detected)
- Remote host / domain (if configured)

### Step 2: `pair.request`
The app attempts connection against candidate endpoints. Once a WebSocket opens, the app sends:
```json
{
  "v": 1,
  "id": "pair-req-1",
  "type": "pair.request",
  "instance_id": "<instance_id>",
  "ts": "2026-11-07T12:00:00Z",
  "data": {
    "pairing_token": "<one_time_token>",
    "device_name": "Phillip's iPhone",
    "client_version": "1.0.0",
    "supported_proto_versions": [1]
  }
}
```

### Step 3: `pair.response`
The plugin validates the one-time token, generates a persistent `device_id` and cryptographically secure `device_token`, records them in its local SQLite `paired_devices` table, and returns:
```json
{
  "v": 1,
  "id": "pair-req-1",
  "type": "pair.response",
  "instance_id": "<instance_id>",
  "ts": "2026-11-07T12:00:01Z",
  "data": {
    "status": "ok",
    "proto_version": 1,
    "device_id": "dev_9f8e7d6c",
    "device_token": "sec_tok_5a4b3c2d1e0f...",
    "instance_name": "Primary Hermes",
    "endpoints": [
      "ws://192.168.1.50:48123",
      "ws://hermes-host.tailnet.ts.net:48123"
    ]
  }
}
```
*Note:* The phone saves `device_token` in iOS Keychain and `endpoints` in local storage.

### Step 4: Subsequent Connection Handshake (`hello`)
Whenever the app reconnects (local Wi-Fi, 5G via Tailscale, or remote), it connects to an available endpoint and sends:
```json
{
  "v": 1,
  "id": "hello-1",
  "type": "hello",
  "instance_id": "<instance_id>",
  "ts": "2026-11-07T12:05:00Z",
  "data": {
    "device_id": "dev_9f8e7d6c",
    "device_token": "sec_tok_5a4b3c2d1e0f...",
    "last_seq": 142,
    "client_version": "1.0.0",
    "proto_version": 1
  }
}
```

### Step 5: `hello.ack`
The plugin verifies the credentials against its store:
```json
{
  "v": 1,
  "id": "hello-1",
  "type": "hello.ack",
  "instance_id": "<instance_id>",
  "ts": "2026-11-07T12:05:01Z",
  "data": {
    "status": "ok",
    "current_seq": 150,
    "instance_name": "Primary Hermes",
    "profiles": [
      { "profile_id": "coder", "name": "Coder", "avatar": "terminal" },
      { "profile_id": "assistant", "name": "General Assistant", "avatar": "sparkles" }
    ]
  }
}
```
Immediately following `hello.ack`, the plugin replays all events with `seq > last_seq` (events 143 through 150) so the phone's cache catches up completely.
