# Auto-reconnect (Phase 1)

After pairing once, the app reconnects to the host by itself: on launch and when returning from the background.

## Saved host (Keychain, this device only)
`instance_id`, `instance_name`, `device_id`, `device_token`, `endpoints`. Endpoints are the route that won the probe first, then the host's `pair.response.endpoints`, then the invite's list, without duplicates. Pairings made before endpoints were saved count as "not paired" and show the wizard once.

## Behaviour
| Situation | What the app does |
|---|---|
| No saved host | Setup wizard |
| Saved host, launch or app comes back to the foreground | "Reconnecting…" screen; probe saved endpoints, send `hello` |
| `hello.ack` ok | Chat screen with the first profile |
| Host returns `error` `AUTH_FAILED` (revoked / unknown token) | Forget the saved host; setup wizard with "This phone is no longer paired…" |
| No endpoint reachable, or other failure | Keep the pairing; show the reason with Try Again and Forget Host |
| Already connected or connecting | Nothing (repeat calls are ignored) |

- `last_seq` in `hello`: 0 on a fresh launch, so the host replays the conversation (the host's store is the source of truth; the phone keeps no chat history on disk yet). After a dropped connection within a session it's the last seq seen, so only new messages arrive.
- A socket that dies after a newer one has connected is ignored, so it can't knock the new connection offline.

## Forget Host
In the chat screen's toolbar and on the Reconnecting screen, with a confirmation. Sends `device.unpair` on its own short-lived socket (2 s probe, 3 s reply timeout) so the host revokes this phone, then deletes the Keychain items, clears the screen and shows the wizard. If the host can't be reached it still forgets locally and the setup screen explains how to revoke the phone with `hermes lekora devices`.

Pairing sends a descriptive `device_name` (hardware model and OS version, e.g. "iPhone19,2 · iOS 27.0.1"); iOS hides the user's own device name from apps.

## Protocol
Uses `pair.request`/`pair.response`, `hello`/`hello.ack`, `error`, and `device.unpair`/`device.unpair.ack` (added for Forget Host), all in `protocol.md`.

## Tests
`app/LekoraTests/AutoReconnectTests.swift` runs against `FakeHost.swift`, a local WebSocket server that answers like the plugin: launch reconnect and history replay, chat after reconnect, `last_seq` after a drop, repeated resume ignored, revoked token, unreachable host, pairing saves the host, invalid pairing code, Forget Host (connected, not connected, host unreachable, already revoked), descriptive device name, and old pairings without endpoints.
