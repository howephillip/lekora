# Decisions

- Rebuild from scratch in a new repo; reuse proven ideas, not code. (2026-11-07)
- Plugin is the backbone; the app is the screen. Hermes-facing behaviour lives in the plugin.
- Hardware-agnostic by rule.
- Push notifications deferred; no paid Apple account needed for now.
- Group chat: user @-mentions agents; context shared by all agents in the chat. Delegation (agent-to-agent) is a separate feature.
- iOS 27 primary, iOS 26 minimum.
- Plugin is public and rebuilt in this repo.
- Plugin-managed dynamic pairing: Pairing is initiated and managed by the plugin rather than bound to a hard physical/local network constraint. The single terminal install produces a pairing token/QR advertising detected endpoints (local LAN, Tailscale, remote). The phone pairs over whichever transport reaches the machine, and authenticates via persistent device credentials that remain valid when switching networks.
- Named Lekora: App and GitHub repository named Lekora across the board. (2026-11-07)
