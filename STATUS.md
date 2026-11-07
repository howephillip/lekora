# STATUS

_Last updated: 2026-11-07_

## Where this is
**Design Approved (`/egm-review` complete and remediated).** The Walking Skeleton specification ([`docs/designs/walking_skeleton.md`](file:///Users/philliphowe/Projects/lekora/docs/designs/walking_skeleton.md)) and wire protocol ([`docs/protocol.md`](file:///Users/philliphowe/Projects/lekora/docs/protocol.md)) are fully aligned with AGENTS.md rules. Port persistence is specified to prevent host restart desync, premature telemetry is stripped from Phase 1, `instance_id` is enforced on all records, profile equality is preserved, and test message schemas (`chat.send`/`chat.message`/`error`) are defined.

## Next up (Implementation)
1. **Host Plugin Build**: Implement Python host plugin (`plugin/lekora/`), dynamic route resolver with bridge filtering, SQLite store with `instance_metadata` port persistence, and async WebSocket gateway.
2. **iOS App Build**: Implement native SwiftUI pairing wizard, Keychain vault, verified RouteProber, and Walking Skeleton ping test view.
3. **Automated Verification**: Run test suite (`pytest plugin/tests`, `swift test`, and E2E mock agent integration test `tests/e2e/test_walking_skeleton.py`).
4. **Owner Confirmation**: Pair and verify ping/pong on a real iPhone.

## Open questions
None.

## Blockers
None. Ready to build.
