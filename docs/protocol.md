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
- `chat.send` is stored as an event (`role: "user"`) and pushed to every connected device, the sender included, carrying `client_id` (the `chat.send` id) so the sender learns its `seq` (changed in Phase 2, see §5). Replies (`role: "assistant"`) go to every connected device. Replay after `hello.ack` includes both roles.
- A repeated `chat.send` `id` on one connection is ignored (idempotent).
- `device.unpair` is accepted before authentication (like `hello`).
- Revocation is checked on every message from an authenticated socket and before every broadcast. A device revoked while connected (e.g. by `hermes lekora devices --revoke` in another process) gets `error` `AUTH_FAILED` for its next message and the socket closes (1008); it receives no further broadcasts.


## 5. Chat history and read state (Phase 2; spec: `chat-history.md`)
All additions are optional fields or new types; protocol version stays 1.

### `hello` adds `since_rev`
`{ ..., "last_seq": 142, "since_rev": 377 }`. `since_rev` is the highest `rev` the phone has seen (0 = no cache). Without it, the host replays everything after `last_seq` as before.

### `hello.ack` adds `rev`, `replay`, `read`
```json
{ "status": "ok", "current_seq": 150, "instance_name": "Primary Hermes", "profiles": [ ... ],
  "rev": 380, "replay": "changes", "read": { "default": 148, "bruce": 120 } }
```
- `replay: "changes"`: the `chat.message`s that follow are every message changed after `since_rev`, in `rev` order (new ones and corrections).
- `replay: "recent"`: the newest 50 messages of each agent follow, in `seq` order. The phone drops its cached saved messages first (its unsent ones stay).
- `read`: each listed agent's read marker (highest `seq` read).

### `chat.message` adds `rev` and `client_id`
`{ "seq": 151, "role": "user", "text": "Hi", "rev": 381, "client_id": "<the chat.send id>" }`. `client_id` only on user messages sent from a phone. A message with a `seq` the phone already has replaces its text (corrections carry a new `rev`).

### `history.fetch` (Client -> Host) / `history.page` (Host -> Client)
```json
{ "type": "history.fetch", "profile_id": "bruce", "data": { "before_seq": 120, "limit": 100 } }
{ "type": "history.page", "id": "<same id>", "profile_id": "bruce",
  "data": { "messages": [ { "seq": 80, "role": "assistant", "text": "...", "rev": 80 } ], "has_more": true } }
```
`messages` are that agent's newest messages older than `before_seq` (all, when omitted), oldest first; `limit` is capped at 100. Unknown agent: `error` `UNKNOWN_PROFILE`.

### `chat.read` (both directions)
`{ "type": "chat.read", "profile_id": "bruce", "data": { "seq": 151 } }`. From a phone: the host moves the agent's marker to `seq` (never backwards) and sends the same `chat.read` to the user's other connected phones. No reply.

### `at` on messages (Phase 2; spec: `agents-home.md`)
`chat.message` data and each `history.page` message carry `at`: when the host saved the message, UTC ISO 8601 (`"2026-11-08T22:42:05Z"`). Optional for the phone: older hosts don't send it. `hello.ack` carries `message_times: true` from hosts that do.

## 6. Permission and question cards (Phase 2; spec: `prompts.md`)

### Cards are chat messages
A card is a `chat.message` with `role` `approval` or `question` and a `card` object; `text` is a one-line summary (for previews and older apps). Status changes resend the same `seq` with a new `rev` (like corrections), so replays and other phones stay in step.
```json
{ "seq": 210, "role": "approval", "rev": 412, "at": "2026-11-08T23:10:00Z",
  "text": "Wants to run: rm -rf ./build",
  "card": { "kind": "approval", "id": "c_5f2a91", "status": "pending",
            "command": "rm -rf ./build", "description": "recursive delete",
            "choices": ["once", "session", "always", "deny"], "smart_denied": false,
            "expires_at": "2026-11-08T23:15:00Z" } }
{ "seq": 214, "role": "question", "rev": 420, "text": "Asks: Which venue?",
  "card": { "kind": "question", "id": "c_77b0c3", "status": "pending",
            "question": "Which venue?", "choices": ["Ramen512", "Kemuri"], "multi_select": false } }
```
A third kind, `confirm` (role `confirm`), is a slash command such as /new asking to be confirmed: `title`, `description`, `choices` `["once","always","cancel"]`, `expires_at`; statuses `pending`, `confirmed_once`, `confirmed_always`, `cancelled`, `answered_in_chat`, `closed`, `expired`. It's answered with `choice`, like an approval.

`status`:
- approval: `pending`, `allowed_once`, `allowed_session`, `allowed_always`, `denied`, `timed_out`, `answered_in_chat`, `closed`, `expired`;
- question: `pending`, `answered`, `answered_in_chat`, `closed`, `expired`.

Answered cards add `answer` (question) or `reason` (a denial's reason). `expires_at` is optional.

### `prompt.respond` (Client -> Host) / `prompt.respond.ack` (Host -> Client)
```json
{ "type": "prompt.respond", "profile_id": "bruce",
  "data": { "card_id": "c_5f2a91", "choice": "deny", "reason": "not now" } }
{ "type": "prompt.respond", "profile_id": "bruce",
  "data": { "card_id": "c_77b0c3", "answers": ["Ramen512"] } }        // or "text": "my own answer"
{ "type": "prompt.respond.ack", "id": "<same id>", "data": { "card_id": "c_5f2a91", "status": "denied" } }
```
- `choice` is one of the card's `choices`.
- `answers`: one or more of the question's choices (several only if `multi_select`).
- `text`: a typed answer ("Other…" or an open question).

A card that's no longer pending (answered on another phone, timed out…) is not an error: the ack carries its current `status`. If Hermes no longer has the request (e.g. it restarted), the card becomes `expired` and the ack says so.

Errors (`error`, same `id`), recoverable:
- `UNKNOWN_CARD`: no such card for that agent.
- `INVALID_ANSWER`: a choice not offered, or an empty answer.

## 7. Slash commands (Phase 2; spec: `slash-commands.md`)
```json
{ "type": "commands.list", "profile_id": "bruce", "data": {} }
{ "type": "commands.list.result", "id": "<same id>", "profile_id": "bruce",
  "data": { "fingerprint": "3f9c0a1b2c3d4e5f",
            "commands": [ { "name": "approvals", "description": "Show or change approval mode",
                            "args": "[manual|smart|off]", "choices": ["manual", "smart", "off"],
                            "aliases": [], "group": "hermes", "category": "Configuration" } ] } }
```
- `group` is one of `hermes`, `plugin`, `skill` or `quick`.
- `fingerprint` changes when the list changes.
- An empty list means the host couldn't read Hermes' commands.
- An unknown agent gets `error` `UNKNOWN_PROFILE`.

## 8. Model and choice pickers (Phase 2; spec: `model-picker.md`)
Cards (§6) with `kind` `model` or `choice`:
```json
{ "kind": "model", "id": "c_1", "status": "pending", "current_model": "claude-opus-5-5", "current_provider": "anthropic",
  "providers": [ { "slug": "anthropic", "name": "Anthropic", "models": ["claude-opus-5-5", "claude-sonnet-5-5"],
                   "is_current": true, "total_models": 2, "model_labels": { "…": "Free" } } ] }
{ "kind": "choice", "id": "c_2", "status": "pending", "title": "**Reasoning**: medium",
  "options": [ { "value": "low", "label": "Low", "is_current": false } ] }
```
Answers use `prompt.respond`:
- model: `{card_id, model, provider, confirmed?}`. The ack may be `needs_confirmation` with `message` (why Hermes wants you to confirm); answer again with `confirmed: true`.
- choice: `{card_id, choice: value}`.

Statuses: `pending`, `chosen` (model cards add `chosen: {model, provider, provider_name}`, choice cards add `answer`), `failed`, `closed`, `expired`.

### Model details (owner's request, 2026-11-09)
Plain requests, each answered with `<type>.result` (same `id`):
- `models.catalog`
  - Sent: `{provider, models?}` (`profile_id` set).
  - Answer: `{provider, complete, models: [{id, name?, maker?, maker_name?, created?, context?, input?, output?, cache_read?, free?, reasoning?, vision?}]}`.
  - Prices are USD per 1M tokens.
  - For OpenRouter, `models` is the whole tool-capable catalog (`complete: true`); otherwise, details of the given ids where Hermes knows them.
- `models.hosts`
  - Sent: `{model}`.
  - Answer: `{model, hosts: [{name, tag, input?, output?, cache_read?, discount?, context?, max_output?, quantization?, uptime?}], routing: {mode, hosts}}`.
- `models.routing.set`
  - Sent: `{model, mode: balanced|cheapest|fastest|one|prefer|only, hosts?: [tag…], no_training?: bool}`.
  - Answer: `{mode, hosts, no_training, backup}`, where `backup` is null when nothing changed.
  - `models.hosts` routing also carries `no_training`, and hosts carry `country`, `privacy_url` and `terms_url`.
  - Errors: `INVALID_ROUTING` (no hosts for prefer/only, or a host not serving the model) and `UNKNOWN_MODEL`.

`prompt.respond` for a model card also accepts any model from OpenRouter's catalog when the provider is `openrouter`.
