# STATUS

_Last updated: 2026-11-07_

## Where this is
**Planning.** Protocol specification for plugin-managed dynamic pairing and connection handshake (`hello/pair`) completed in `docs/protocol.md`.

## Next up
1. Build the walking skeleton:
   - Plugin: WebSocket listener, dynamic port selection, SQLite `paired_devices` store, and terminal pairing invite command (`pair.request` / `pair.response`).
   - App: Minimal SwiftUI screen to scan/paste pairing invite, store token in Keychain, and exchange `hello` / `hello.ack`.
2. Stream a test ping/message through to verify end-to-end connectivity.

## Open questions
- Which Hermes versions to support.

## Blockers
None.
