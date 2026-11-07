# Decisions

- Rebuild from scratch in a new repo; reuse proven ideas, not code. (2026-11-07)
- Plugin is the backbone; the app is the screen. Hermes-facing behaviour lives in the plugin.
- Hardware-agnostic by rule.
- Push notifications deferred; no paid Apple account needed for now.
- Group chat: user @-mentions agents; context shared by all agents in the chat. Delegation (agent-to-agent) is a separate feature.
- iOS 27 primary, iOS 26 minimum.
- Plugin is public and rebuilt in this repo.
