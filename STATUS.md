# STATUS

_Last updated: 2026-11-08_

## Where this is
**Phase 1 (Foundation) is complete** (confirmed on your iPhone and Hermes machine 2026-11-08). Pair by QR or link over encrypted, certificate-pinned connections; chat; auto-reconnect; device management; iOS 26 design system; choosing, switching, creating and deleting your real Hermes agents. 152 plugin tests and 69 app tests passed at the end of Phase 1.

**Phase 2 (complete chat) has started.**

## In progress: streaming replies (spec: `docs/streaming.md`)
⏳ Built: replies appear word by word, with a "thinking…" line showing what the agent is doing ("Searching the web…"). Streaming is switched on for Lekora only, in memory (no Hermes config change, no command for you; other messaging apps keep their own setting); if a Hermes update breaks that, replies arrive whole as before. Finished replies are saved as normal messages, so history and replay are unchanged. Plugin 176 tests, app 79; real app checked against the real plugin over the encrypted connection. First phone test (2026-11-08): streaming works with your real Hermes. Your feedback fixed: blank lines around agent text trimmed and Markdown rendered (bold, links…); Hermes' own notices (restart, gateway online, background task) shown as small system lines instead of bubbles; the "Working — N min" heartbeat removed from the chat (the thinking line now shows "· 12 min"); status reads "Default is using…"; smooth iMessage-style dots. Plugin 186 tests, app 84. Waiting on: plugin update and your second look.

## Done: create and delete agents from the phone (spec: `docs/agent-lifecycle.md`)
✅ Confirmed on your iPhone and Hermes machine 2026-11-08: created an agent from the phone, chatted with it, deleted it (backup kept in `~/.hermes/lekora-backups/profiles/`), and `default` offers no delete. "Manage Agents…" in the chat's agent menu → Add Agent (clones your default agent's settings) and swipe-left / long-press → Delete with confirmation. The host runs Hermes' own `hermes profile` commands, refuses to delete `default`, needs explicit confirmation, and backs up first; if the backup fails, nothing is deleted. Other phones update live.

## Done: choosing and switching agents (spec: `docs/agents.md`)
✅ Confirmed on your iPhone and Hermes machine 2026-11-08: named agents (e.g. Bruce) answer as themselves, Default still works, each keeps its own chat. Built: the plugin now offers your real Hermes profiles and sends each message to the agent you chose (no Hermes config changes); the app adds a Choose Agents step and an agent switcher (tap the agent name at the top of the chat). Plugin 105 tests, app 47 tests; real app checked against the real plugin with three profiles. Also fixed a pre-existing flaky WebSocket test (1009 close frame could be lost). First phone test (2026-11-08): your agents all appeared and the switcher worked, but named agents (e.g. Bruce) answered `profile_mismatch`: Hermes refuses a profile chosen by an add-on unless its own routing table agrees. Fixed in the plugin with in-memory routes (no Hermes config written; self-check falls back to Default-only if a Hermes update breaks it). Plugin 116 tests.

## Done: iOS 26 target + design system (spec: `docs/design-system.md`)
✅ Approved by you on your iPhone 2026-11-07. App now requires iOS 26 (Xcode project and `Package.swift`). Liquid Glass for controls (message bar, buttons, badges), solid surfaces for content (bubbles, cards). Setup, Reconnecting and Chat restyled; checked in previews (light, dark, large text). 33 app tests pass. Your feedback applied (2026-11-07): iMessage blue instead of indigo; the unclear "● C" connection badge removed from the chat.

## Done: auto-reconnect (spec: `docs/auto-reconnect.md`)
✅ Confirmed on your iPhone on 2026-11-07: after pairing, closing and reopening Lekora goes straight to the chat with earlier messages restored from the host; coming back from the home screen keeps chat working; Forget Host returns to the setup screen. The "device revoked" and "host unreachable" paths are covered by automated tests against a fake host only (13 new tests, 29 total, stable over repeated runs).

## Done: chat screen (spec: `docs/chat-screen.md`)
✅ Confirmed on your iPhone on 2026-11-07: typed a message, the real agent's reply came back as a left-hand bubble. Text bar, chat bubbles, auto-scroll and delivery status. Duplicate-free replay after a reconnect is covered by automated tests. 8 new app tests (16 total) pass with `swift test`.

## Host plugin build order
1. ✅ `store.py` — database, one-time invites (30 min, single use), device tokens (hashed), event numbering, saved port.
2. ✅ `routes.py` — find phone-reachable addresses (LAN + Tailscale), skipping Docker/virtual adapters. 10 tests; also smoke-run on this Mac.
3. ✅ `gateway.py` — WebSocket server: pairing, reconnect, replay, Ping → Pong. 17 tests against a real socket (40 plugin tests total).
4. ✅ `plugin.py` — version check, service wiring, clean Hermes bridge. `hermes_adapter.py` is the real Hermes platform adapter, written from Hermes' own docs and IRC example on this Mac (Hermes 0.22.5) now confirmed running inside real Hermes.
5. ✅ `pairing.py` + `qr.py` — `hermes lekora pair` with QR code, link and token. The QR codes were decoded back correctly by Apple's own QR reader, so they scan.
5b. ✅ `ws.py` — plugin now has **zero third-party dependencies** (own WebSocket server; `websockets` is test-only). 14 protocol tests.
6. ✅ Fake-Hermes end-to-end test passes (`tests/e2e/test_walking_skeleton.py`): pair → hello → Ping/Pong → restart → same port → catch-up. 81 tests total.
7. ✅ **Real-Hermes pass (walking skeleton)** — plugin installed from GitHub on your Hermes test machine via `docs/install.md`; pair → hello → Ping/Pong worked from your iPhone (2026-11-07). A real chat message to the agent and its reply also worked (2026-11-07).
8. ✅ Owner confirmed on a real iPhone (2026-11-07): QR scan, pairing and Ping/Pong against the real host.

### Resolved: this Mac's `~/.hermes` is back to its original state
The plugin had been installed here by mistake (Hermes runs on a separate Tailscale machine). It was fully removed on 2026-11-07: plugin deleted, `config.yaml` restored byte-for-byte from `~/.hermes/backups/config/config.yaml.pre-lekora.20261107-162316` (kept), gateway restarted, `lekora.db` deleted, nothing listening on the Lekora port.
## Follow-ups found in live test
- ✅ "No home channel" notice: the plugin sets a home channel in memory only (first profile); nothing is written to your Hermes config. Confirmed on real Hermes 2026-11-07: the notice only appeared on the very first Ping (before the fix was installed) and not on later messages.
- ✅ QR scanning works on your iPhone (confirmed 2026-11-07): scanned, paired over the real host, Ping → Pong. The "black camera" was not a Lekora bug: iOS blanks the camera while Xcode is screen-sharing the phone (Apple's Camera app went black too). Avoid screen sharing when testing the scanner.
- ✅ Scanning up close fixed, in two parts. App: uses the multi-lens camera (switches to macro up close) with near-focus. Plugin: the terminal QR now draws black squares only as cell background; macOS Terminal drew the old half-block characters slightly low, cutting white lines through the QR's corner squares. Confirmed on your phone against a test QR in Terminal: scans quickly up close. 82 plugin tests pass.
- ✅ Fix pushed to GitHub and reinstalled on your Hermes machine; re-paired successfully with the new QR (2026-11-07).
- ✅ Chat view complete: text input bar, auto-scroll, message bubbles, and real agent replies verified on your iPhone (2026-11-07).
- ✅ Auto-reconnect on app launch: app reuses saved credentials from Keychain, skips setup, and restores chat history. Confirmed on iPhone 2026-11-07.
- ✅ `hermes lekora devices` lists paired phones; `--revoke <ID>` removes one. A phone revoked while connected is cut off at its next message. 13 new tests (95 plugin tests). Installed on your Hermes machine and used to revoke the leftovers (2026-11-08).
- ✅ Forget Host removes the phone from the host (`device.unpair`); pairings get a descriptive name; `devices` shows when each was paired. Confirmed on your phone and Hermes machine 2026-11-08: after Forget Host and re-pairing, exactly one active device (`iPhone19,2 · iOS 27.0.1`); leftovers revoked. Plugin 98 tests, app 33.
- ✅ Signing team is now set in the project settings (your Personal Team), so it no longer gets lost when the project is regenerated. A command-line build for iPhone succeeds.

Done since: tapping a `lekora-pair://` link now starts pairing (bad links show a clear error); Keychain errors are readable; route-probe crash fixed. Event 1/2 gap is expected (ping and pong are stored on the host).

## Open / known limits
- 🐞 **Fixed, needs your update (2026-11-08): pairing codes pointed at a dead port.** Creating an agent from the phone started a second copy of Lekora inside that agent's profile. That copy moved to port 40225 and saved it over the real port (45733), so every new code advertised a port nothing listened on. Your existing pairing kept working; only new codes broke. Fix: Lekora runs only from the default profile (other copies stay idle), one copy per machine (lock), and `hermes lekora pair` refuses to print a code for a port nothing answers on. Plugin 144 tests.
- ✅ Pairing by link (copied to the phone) confirmed on your iPhone 2026-11-08, after the dead-port fix.
- ✅ Encrypted connections (spec: `docs/encryption.md`): plugin-made certificate, fingerprint in the pairing code, phone accepts only that certificate, plain `ws://` refused on both sides. Confirmed on your iPhone and Hermes machine 2026-11-08.
- Known limits (by design, documented in the specs): agent routing uses Hermes internals (re-check after Hermes upgrades; the plugin falls back to Default-only if they change); chat history isn't stored on the phone between launches (replayed from the host); no unread indicator for other agents; agent display names come from their IDs.
