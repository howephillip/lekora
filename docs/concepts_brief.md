# Lekora: Concepts Brief

## 1. Executive Summary & Problem
Lekora is a native iOS companion app (SwiftUI, targeting iOS 27 primary, iOS 26 minimum) and companion plugin that connects seamlessly to any existing Hermes agent installation. Current agent interfaces either require heavy web-UI servers or custom API wrappers. Lekora acts as a native messaging platform to Hermes, requiring zero Hermes modifications and a single-command install on the host machine.

## 2. Core Pillars & Differentiators
- **Voice-First**: Bidirectional streaming speech, per-agent voice stylization, scrubbable transcripts, and hands-free driving/walk mode.
- **Interactive Sandboxed Artifacts**: Agents generate rich HTML, documents, and code via plugin tools rendered in isolated web views.
- **True Two-Way File Sharing**: Native plugin tools for sending and receiving media, binaries, and documents without prompt manipulation.
- **Full Operational Parity**: Equal treatment for all agent profiles, native Kanban sync, and full cron/scheduler management.
- **Persistent Live Gateway**: One WebSocket connection allowing agents to initiate proactive messages to the user.

## 3. Key Architectural Decisions (Aligned in Brainstorming)
- **Plugin-Managed Dynamic Pairing**: No brittle network binds ("hard pairs"). The plugin generates an invitation token advertising all reachable routes (Local LAN, Tailscale MagicDNS/IP, remote hostname). The phone connects over whichever route is open and obtains a persistent device credential saved to Keychain.
- **Host as Source of Truth**: SQLite database on the Hermes machine holds all chats, metadata, and artifacts. The iPhone is a high-speed local cache; replacing or resetting a phone recovers the complete state immediately.
- **Monotonic Event Sequencing (`seq`)**: Offline queuing without paid Apple push notifications. Upon reconnect, the app supplies `last_seq` and replays all missed events.
- **Non-Invasive Integration**: Hermes is never forced to expose an external API; the plugin connects natively as a messaging client.

## 4. Phase 1 Milestone: The Walking Skeleton
- **Plugin**: WebSocket listener on a dynamic port, SQLite `paired_devices` store, CLI command generating pairing QR/token.
- **App**: Setup wizard to scan/paste pairing invite, authenticate handshake (`pair.request` / `pair.response`), and persist session.
- **End-to-End Test**: Send "Ping", stream reply back from Hermes agent.

## 5. Next EGM Step
Transition to `/egm-draft` to construct the formal technical design doc and file-level implementation plan.
