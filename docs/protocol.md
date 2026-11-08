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
lekora-pair://pair?token=<one_time_token>&instance_id=<instance_id>&endpoints=<url_encoded_csv>&fp=<cert_fingerprint>
```
All connections are encrypted (`wss://`); see `encryption.md`. `fp` is the host certificate's fingerprint, base64url(SHA-256(DER)) without padding. The phone accepts only that certificate and refuses links without `fp` or with plain `ws://` addresses.

Endpoints include all detected routes:
- Local LAN (e.g. `wss://192.168.1.50:48123`)
- Tailscale (e.g. `wss://hermes-host.tailnet.ts.net:48123` if Tailscale is detected)
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
      "wss://192.168.1.50:48123",
      "wss://hermes-host.tailnet.ts.net:48123"
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
      { "profile_id": "default", "name": "Default", "avatar": "sparkles" },
      { "profile_id": "work", "name": "Work", "avatar": "sparkles", "description": "Email and calendar" }
    ]
  }
}
```
`profiles` are the real Hermes profiles on the host, discovered live on every `hello` (`default` first, then named profiles alphabetically; deleted and parked profiles are left out). `profile_id` is the Hermes profile name; `name` is its `display_name` from `profile.yaml`, else a readable form of the id; `description` (optional) comes from `profile.yaml`. A `profile_id` on `chat.send` is checked against this list at send time, so a profile deleted since `hello` gets `UNKNOWN_PROFILE`.

Immediately following `hello.ack`, the plugin replays all events with `seq > last_seq` (events 143 through 150) so the phone's cache catches up completely.

---

### Step 6: `device.unpair` (Client -> Host) — the app's "Forget Host"
Sent on a fresh socket, **without** `hello` (no replay): it carries its own credentials.
```json
{
  "v": 1,
  "id": "c3d4e5f6-0000-4000-8000-000000000001",
  "type": "device.unpair",
  "instance_id": "<instance_id>",
  "ts": "2026-11-07T21:05:00Z",
  "data": { "device_id": "dev_8f7e6d5c", "device_token": "sec_..." }
}
```
The host verifies the token, revokes the device, replies `device.unpair.ack` with the same `id`, then closes this socket and any other open socket of that device (code 1000):
```json
{ "v": 1, "id": "<same id>", "type": "device.unpair.ack", "instance_id": "<instance_id>",
  "ts": "2026-11-07T21:05:00Z", "data": { "status": "ok", "device_id": "dev_8f7e6d5c" } }
```
A wrong or already-revoked token gets `error` `AUTH_FAILED` (the app treats "already revoked" as done). If the host can't be reached the app forgets locally anyway and points the user to `hermes lekora devices`.

## 2. `chat.*` (Walking Skeleton Ping/Pong)

In Phase 1 (Walking Skeleton), chat messages confirm bidirectional end-to-end communication between the mobile app and the Hermes agent via the native platform hook.

### `chat.send` (Client -> Host)
The mobile app dispatches a user message to the specified agent profile:
```json
{
  "v": 1,
  "id": "a1b2c3d4-e5f6-7a8b-9c0d-1e2f3a4b5c6d",
  "type": "chat.send",
  "instance_id": "<instance_id>",
  "profile_id": "assistant",
  "ts": "2026-11-07T21:05:00Z",
  "data": {
    "text": "Ping"
  }
}
```

### `chat.message` (Host -> Client)
The host delivers the sequenced response from the Hermes agent:
```json
{
  "v": 1,
  "id": "e5f6a7b8-c9d0-1e2f-3a4b-5c6d7e8f9a0b",
  "type": "chat.message",
  "instance_id": "<instance_id>",
  "profile_id": "assistant",
  "ts": "2026-11-07T21:05:01Z",
  "data": {
    "seq": 106,
    "role": "assistant",
    "text": "Pong from Hermes"
  }
}
```

---

### Streaming: `chat.draft` and `chat.typing` (Host -> Client)
See `streaming.md`. Neither is stored or replayed.
- `chat.draft` `{draft_id, text}`: the full text so far of a reply being written. Empty `text` drops it.
- `chat.typing` `{active, status?}`: whether the agent is working, and on what.
- A saved `chat.message` may carry `draft_id`, so the phone replaces that live bubble.
- A `chat.message` with a `seq` the phone already has replaces its text (an agent's correction).

---

## 3. `error` (Host -> Client)
Standardized error responses delivered when a request fails or session authentication fails:
```json
{
  "v": 1,
  "id": "d0e1f2a3-b4c5-6d7e-8f9a-0b1c2d3e4f5a",
  "type": "error",
  "instance_id": "<instance_id>",
  "ts": "2026-11-07T21:00:01Z",
  "data": {
    "code": "AUTH_FAILED",
    "reason": "Invalid or revoked device token",
    "recoverable": false
  }
}
```
Standard error codes: `TOKEN_EXPIRED`, `TOKEN_INVALID`, `AUTH_FAILED`, `INCOMPATIBLE_VERSION`.

Added by the host gateway (Phase 1):
- `INVALID_MESSAGE`: malformed JSON, wrong `instance_id`, empty `text`, or unknown message type.
- `UNKNOWN_PROFILE`: `chat.send` named a profile the host does not have (recoverable).
- `AGENT_ERROR`: the agent could not take the message (recoverable).

Auth-related errors (`TOKEN_*`, `AUTH_FAILED`, `INCOMPATIBLE_VERSION`) close the socket (code 1008) after the error is sent. An unauthenticated socket that sends nothing valid within 5 seconds is closed with code 1008.

## 4. Gateway behaviour notes (Phase 1)
- A successful `pair.request` also authenticates that socket; the app may send `hello` on the same socket straight afterwards.
- `chat.send` is stored as an event (`role: "user"`) and pushed to the sender's *other* devices only; replies (`role: "assistant"`) go to every connected device. Replay after `hello.ack` includes both roles.
- A repeated `chat.send` `id` on one connection is ignored (idempotent).
- `device.unpair` is accepted before authentication (like `hello`).
- Revocation is checked on every message from an authenticated socket and before every broadcast. A device revoked while connected (e.g. by `hermes lekora devices --revoke` in another process) gets `error` `AUTH_FAILED` for its next message and the socket closes (1008); it receives no further broadcasts.

