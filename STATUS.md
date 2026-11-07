# STATUS

_Last updated: 2026-11-07_

## Where this is
**Host plugin code complete; waiting on the real-Hermes pass and your phone.** The Python plugin (storage, route detection, WebSocket server, pairing command with QR, Hermes adapter) is built with 81 passing automated tests, including a fake-Hermes end-to-end run. The iOS client is complete and passes its 8 tests on the simulator. Next: install on your Tailscale test machine with the command in `docs/install.md`, then pair a real iPhone.

## Host plugin build order
1. ✅ `store.py` — database, one-time invites (30 min, single use), device tokens (hashed), event numbering, saved port.
2. ✅ `routes.py` — find phone-reachable addresses (LAN + Tailscale), skipping Docker/virtual adapters. 10 tests; also smoke-run on this Mac.
3. ✅ `gateway.py` — WebSocket server: pairing, reconnect, replay, Ping → Pong. 17 tests against a real socket (40 plugin tests total).
4. ✅ (fake-Hermes tested; real Hermes NOT yet) `plugin.py` — version check, service wiring, clean Hermes bridge. `hermes_adapter.py` is the real Hermes platform adapter, written from Hermes' own docs and IRC example on this Mac (Hermes 0.22.5) but not yet run inside Hermes. 57 plugin tests pass.
5. ✅ `pairing.py` + `qr.py` — `hermes lekora pair` with QR code, link and token. The QR codes were decoded back correctly by Apple's own QR reader, so they scan.
5b. ✅ `ws.py` — plugin now has **zero third-party dependencies** (own WebSocket server; `websockets` is test-only). 14 protocol tests.
6. ✅ Fake-Hermes end-to-end test passes (`tests/e2e/test_walking_skeleton.py`): pair → hello → Ping/Pong → restart → same port → catch-up. 81 tests total.
7. ⏳ **Real-Hermes pass** — to be run on the owner's separate Tailscale test machine using `docs/install.md`. Already verified on this Mac before that was clarified: Hermes accepts the plugin, the gateway connects Lekora, and pair/hello worked against it (no chat message sent).
8. ⏳ Owner test on a real iPhone.

### Resolved: this Mac's `~/.hermes` is back to its original state
The plugin had been installed here by mistake (Hermes runs on a separate Tailscale machine). It was fully removed on 2026-11-07: plugin deleted, `config.yaml` restored byte-for-byte from `~/.hermes/backups/config/config.yaml.pre-lekora.20261107-162316` (kept), gateway restarted, `lekora.db` deleted, nothing listening on the Lekora port.
## Follow-ups found in live test
- Hermes shows a "no home channel" notice on the first message; the plugin should handle it.
- App allows plain `ws://` to any address (ATS exception); consider tightening.
- Revoke the half-finished device from the earlier failed attempt on the host.
- Owner to pick a developer team in Xcode and sign off on a real iPhone (bundle ID `app.lekora.Lekora`).

Done since: tapping a `lekora-pair://` link now starts pairing (bad links show a clear error); Keychain errors are readable; route-probe crash fixed. Event 1/2 gap is expected (ping and pong are stored on the host).
