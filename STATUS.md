# STATUS

_Last updated: 2026-11-10_

README rewritten (2026-11-09): outward-facing, alpha status, build-in-Xcode steps, PolyForm Noncommercial LICENSE, screenshots in docs/screenshots (made with tools/demo_host.py, a fake Hermes with made-up agents). Not committed yet.

## Where this is
**Phase 1 (Foundation) is complete** (confirmed on your iPhone and Hermes machine 2026-11-08). Pair by QR or link over encrypted, certificate-pinned connections; chat; auto-reconnect; device management; iOS 26 design system; choosing, switching, creating and deleting your real Hermes agents. 152 plugin tests and 69 app tests passed at the end of Phase 1.

**Phase 2 (complete chat) is complete** (all seven features confirmed on your iPhone, 2026-11-10). **Phase 3 (files both ways) is complete** (confirmed on your iPhone 2026-11-11). **Phase 4 (voice) has started:** voice notes are built and waiting for your phone check; then hearing replies, then hands-free.

## Ready for your phone check: voice notes (Phase 4, feature 1; spec: `docs/voice.md`)
- **What it does (as in Messages, your request 2026-11-11):** a waveform button inside the message bar while nothing is typed (typing turns it into Send). Hold it for a second (a red ring fills, so a stray tap does nothing), then let go and talk; a haptic marks the start; the bar becomes a red live waveform with the time and a stop button. After stopping: × on the far left throws it away; play it back, "+ 0:07" records more onto the end, and Send. Your note shows as a voice bubble (play/pause, waveform you drag to skip, length) and what Hermes heard appears under it in small grey print. The agent then answers the words.
- **Your first try (2026-11-11):** worked; changed to the Messages-style recording above (review before sending, record more, × to discard, record button inside the bar). **Second look:** hold for 1 second to start, haptics back (start, stop), and the bar now springs between idle, recording and review instead of popping. Checked in the simulator with the real plugin (the animations need your eyes on the phone).
- **Your choices (2026-11-11):** transcript in small print under the bubble; for Phase 4 overall, iPhone voices by default with a per-agent Hermes voice option, and hands-free built in this phase.
- **How:** the recording is sent like a file, marked as a voice note, so Hermes transcribes it with its own speech-to-text (a free one on your Pi by default; the first note may take a minute while Hermes sets it up). Hermes' "🎙️ …" line is put under your bubble instead of showing on its own.
- **Checked:** plugin 314 tests (5 new), app 162 (3 new); in the simulator with the real plugin: record, transcript under the bubble with no extra line, play, skip, slide to cancel, quick taps. Fixed from that: the mic could keep recording after a quick tap or while iPhone asked for microphone permission.
- **Needs from you:** `hermes plugins update lekora`, restart Hermes, then record a note on your phone (allow the microphone when asked).

## Done: files both ways (spec: `docs/files.md`)
✅ Confirmed on your iPhone with real Hermes 2026-11-11.
- **What it does:** a **+** next to the message box: Photo Library (up to 10), Take Photo, Choose Files. Attachments show as small previews (× to remove) and upload with a progress ring; then the message is sent. Photos show as pictures in the chat, other files as a row with icon, name and size; tap any to open Apple's preview (zoom, read, play, share or save). Agents send files back two ways: Hermes' own file sending (e.g. generated images) and a real `lekora_send_file` tool offered only in Lekora chats. The instance page shows "Files: 11.2 MB · 5 files".
- **Your choices (2026-11-10):** files kept forever on the instance (`<Hermes>/lekora-files/`), 100 MB per file, voice notes in Phase 4. Deleting an agent moves its files into that agent's backup, next to its chats.
- **How:** files go to Hermes the way Telegram's do (Hermes' own media cache), so Hermes handles photos (vision), small text files (read directly) and other documents as usual. iPhone HEIC photos are sent as JPEG.
- **Checked:** plugin 309 tests (14 new), app 159 (6 new); in the simulator with the real plugin and a stand-in Hermes: photo with text and back, PDF from the agent opened in the preview, two photos with one removed, photo-only messages, agents list preview, storage line. Fixed from that: photos ran a few points off the screen edge.

## Done: multiple Hermes instances (spec: `docs/multiple-instances.md`)
✅ Confirmed on your iPhone 2026-11-10 with the Pi and omacron (you'll do deeper testing later; anything found gets fixed as a follow-up). Since then the app says "Hermes instance" instead of "computer" everywhere in this feature (your request).
- **What it does:** pair more than one Hermes instance. "…" → **Hermes Instances…** lists them (connected or not), with **Add Hermes Instance**, **Rename…** and **Forget This Instance** for each. The agents list shows every instance's agents: **Sort by Recent** (default, with a small grey instance name after each agent once you have two) or **Group by Instance** (a section per instance), switchable in the "…" menu. + asks which instance to add an agent on; the chat header shows the instance's name.
- **Your choices (2026-11-10):** both layouts, recent first by default; instances can be renamed, and the name is saved on the instance so every phone sees it.
- **Also:** an instance without a name now shows its own network name (e.g. "omacron") instead of "Hermes". Your current Pi pairing moves over by itself; nothing to redo. One instance being off doesn't affect the others.
- **Checked:** plugin 295 tests (4 new), app 153 (11 new); in the simulator with the real plugin and two stand-in instances (adding, renaming, both layouts, chats kept apart, relaunch).
- **Fixed 2026-11-10 (your first try):** when an instance dropped (e.g. Hermes restarting), the app retried it many times a second, flooding it and making the phone sluggish. Cause: the every-20-seconds retry also fired the moment the agents list closed, which (with one instance) reopened it. Fixed, plus a safety net: after a failed attempt an instance is retried at most once every 2 seconds. Checked in the simulator: one or two attempts in 40 s instead of thousands.

## Done: per-chat settings (spec: `docs/chat-settings.md`)
✅ Confirmed on your iPhone with real Hermes 2026-11-10.
- **What it does:** tap the agent at the top of a chat to open **Chat Settings**: chat name (tap to rename), model, how full the chat's memory is, cost so far; this session's Reasoning, Fast Mode and **Auto-Approve**; the agent's Personality, Approvals and Show Reasoning; and New Chat / Compress / Retry / Undo. The model now shows under the agent's name in the chat header.
- **Auto-Approve (your Option A):** asks before turning on, and while it's on (or Approvals is "Never Ask") a small amber **Auto** badge sits in the chat header.
- **How:** every change is Hermes' own command (`/reasoning high`, `/yolo`…), so Hermes applies and saves it and replies in the chat. Nothing in Hermes' config is written by the plugin for this.
- **Checked:** plugin 291 tests (new ones for settings), app 142 (5 new); in the simulator against the real plugin with a stand-in Hermes: the sheet, the warning, the badge appearing and disappearing, reasoning/fast changes, compress. The simulator found the header badge staying after Auto-Approve was turned off; fixed and rechecked.

## Done: model picker (spec: `docs/model-picker.md`)
✅ Confirmed on your iPhone with real Hermes 2026-11-09 (after four rounds of your feedback).
- **What it does:** a Model button in each chat (or typing `/model`) shows a card with the agent's current model and **Choose a Model…**: a searchable list of every model your Hermes computer can use, by provider. Tap one and Hermes switches and confirms. A model Hermes flags (e.g. expensive) asks "Switch anyway?" first. `/reasoning` and `/fast` get a card with one button per option.
- **How:** Hermes' own picker hooks (the ones Telegram, Discord and Slack use); Hermes does the switching and decides whether it's saved.
- **Checked:** plugin 256 tests (6 new), app 132 (4 new); every Hermes hook checked against Hermes 0.22.5's source; in the simulator against the real plugin: the Model button, the searchable list, switching, the "Switch anyway?" check, and the /reasoning card.
- **Your first look (2026-11-09): prices, all OpenRouter models, and their hosts.** Every model now shows its price, context size and badges (reasoning, images, free). "Browse all OpenRouter models" opens OpenRouter's whole tool-capable catalog (~400) with search, sorting and filters. The (i) on a model shows every company hosting it (prices, uptime, setup) and lets you choose Balanced / Cheapest / Fastest / Prefer these / Only these. That's saved in Hermes' own routing setting for that model (the rule-8 exception you agreed: one setting, backed up first to `lekora-backups/config/`, original kept forever plus the 10 newest). Plugin 270 tests (14 new), app 136 (4 new); checked in the simulator with OpenRouter's real catalog and the DeepSeek host list from your screenshot.
- **Your second look (2026-11-09):**
  - Tapping a model now asks Use This Model / Advanced… / Cancel (no more (i) button).
  - The model page starts with a designed summary card.
  - Routing adds "One Host" (just the host you tap) and "No training on my data". OpenRouter's public data doesn't say which hosts train on prompts, so this tells OpenRouter to skip any that do (Hermes' `data_collection: deny`).
  - Hosts show where they're based, with their privacy policy and terms on a long press.
  - Search matches every word.
  - Plugin 270 tests, app 136; checked in the simulator with OpenRouter's real data.
- **Your third look (2026-11-09):**
  - Switches said "session only".
  - Picking a model now asks **Use in This Chat** or **Use in All Chats**. These use Hermes' own `--session` / `--global`; "All Chats" makes Hermes save it as that agent's default.
  - Plugin 271 tests, app 137; checked in the simulator.
- **Your fourth look (2026-11-09):** the buttons now say it plainly: **This Session Only** / **Always Use for <agent>**, and the card afterwards matches. App-only change.

## Done: slash commands (spec: `docs/slash-commands.md`)
✅ Confirmed on your iPhone with real Hermes 2026-11-08.
- **What it does:** typing `/` shows the agent's commands just above the message bar, each with a short description, narrowing as you type. Commands with fixed options (e.g. `/approvals` manual · smart · off) offer them next. Tapping fills the bar; you send.
- **Where the list comes from:** Hermes' own lists, the same ones its Telegram and Discord menus use: built-in commands (with Hermes' own descriptions, in your language), your plugins' and skills' commands, and your `quick_commands`. Read for each agent separately (skills and plugins can differ per agent), every time its chat opens, so new skills appear without an app update.
- **Checked:** plugin 250 tests (6 new, including reading Hermes' sources with stand-ins), app 128 (6 new); every Hermes name used checked against Hermes 0.22.5's source; in the simulator against the real plugin: the list, narrowing, aliases, options, inserting, sending.

## Done: permission pop-ups and question cards (spec: `docs/prompts.md`)
✅ Confirmed on your iPhone with real Hermes 2026-11-08.
- **Approvals:** when Hermes pauses an agent to ask permission (a risky command), the chat shows a card with the command, why it asks, a countdown, and Deny / Allow / "…" (Allow for this chat, Always allow, which asks you to confirm first). Deny takes an optional reason the agent sees. Afterwards the card shows the outcome ("Allowed once", "Denied — not now", "Timed out — nothing ran").
- **Questions:** when an agent asks you to choose, a card with a button per option (or ticks for several), "Other…" for your own answer, or an answer box for open questions.
- **Everywhere:** an agent waiting on you shows "Needs your approval" / "Has a question" in orange on the agents list; cards count as unread; they're saved with the chat on the Hermes computer, so every phone sees them and answering on one updates the others. Cards that can't be answered any more say why.
- **How:** uses Hermes' own button hooks (the ones Telegram/Slack use) and its own answer functions; nothing in Hermes' config is touched by Lekora. "Always allow" is Hermes' own setting, saved by Hermes when you choose it.
- **Checked:** plugin 239 tests (20 new), app 121 (10 new); every Hermes function and field the plugin uses checked against Hermes 0.22.5's source; in the simulator against the real plugin: allow, deny with reason, always allow with confirmation, question choice, "Other…", list labels, and the card staying still under your finger. Not yet: the real Hermes pass (your Hermes machine).
- **First real test (2026-11-08):** `/new` showed Hermes' plain-text confirmation ("reply /approve, /always, or /cancel"). That's a third kind of Hermes prompt (slash-command confirmations) I hadn't covered; now a confirmation card too: Cancel / Approve / "…" Always approve (asks first), then Hermes' result as a small line. Plugin 244 tests, app 122.

## Done: agents home (spec: `docs/agents-home.md`)
✅ Confirmed on your iPhone and Hermes machine 2026-11-08 (after two rounds of your feedback).
- **Home:** the app opens on a Messages-style list of your agents. Each has its own playful avatar (a critter on a colour gradient; no two of your agents share colours), the last message, its time ("3:31 PM", "Yesterday", "Wednesday"), and a blue dot for unread replies. While an agent works, its row shows the moving dots and what it's doing. The most recent conversation is at the top. "+" adds an agent; "…" has Manage Agents and Forget Host.
- **Chat:** unchanged iMessage look. The title shows the agent's avatar and name; time lines appear between messages more than 15 minutes apart; the back button shows how many other agents have unread replies ("‹ 2"); "## headings" show as bold lines; an unsent message stays in its chat while you switch.
- **Plugin:** messages carry the time they were saved; messages already cached on your phone are fetched again once to pick up their times.
- **Checked:** plugin 219 tests, app 110 tests (11 new); three rounds in the simulator against the real plugin over the encrypted connection (order, avatars, previews, working line, unread dots, back-button count, drafts, newest message fully visible on opening).
- **Your first look (2026-11-08), fixed:** sent text stayed in the message bar; no swipe to go back; "Hermes" shown under the titles; avatars now gently animated (float, sway, drifting light; livelier while working); drag the chat left to see every message's time, as in Messages. Times on messages need the plugin update (the phone only learns them from the updated plugin). Checked in the simulator: bar clears after sending, swipe back from the edge and mid-screen, time reveal, no "Hermes", avatars moving.
- **Your second look (2026-11-08), fixed:** the sent text still stayed in the bar (now a fresh text box after each send, keyboard kept up); times disappeared after reopening (the app no longer throws away its saved messages to refetch times; your own messages keep their time; agents' times arrive once the plugin is updated); new jump-to-newest ⌄ button; avatars are now little visor bots that blink, glance around, bob and wobble their antennas. Checked in the simulator; app 111 tests, plugin 219.

## Done: chat history on the phone, and unread dots (spec: `docs/chat-history.md`)
✅ Confirmed on your iPhone and Hermes machine 2026-11-08: the dots appear and clear.
- **On the phone:** chats are kept between launches, so the app opens straight to your conversation ("Connecting…" under the name until the host answers); on reconnecting it fetches only what changed, including corrections an agent made while the app was closed. A new phone (or a long absence) gets each agent's newest 50 messages; older ones load 100 at a time as you scroll up, without losing your place.
- **Unread dots:** a blue dot next to the agent's name in the title when another agent has replies waiting, and a blue dot plus "New messages" under that agent in the switcher. Opening the chat clears it, on every phone (read state is kept on the Hermes machine). Everything already in your chats counts as read after the update.
- **Also fixed:** the app could wrongly say "the computer that answered isn't the Hermes computer this iPhone was paired with" when a connection attempt was simply cut short or the computer was off.
- **Checked:** plugin 219 tests (15 new), app 99 tests (15 new); the app against the real plugin code (recent replay, older pages, own messages, read state, cache after relaunch, a correction made while away); and in the simulator over the encrypted connection: dots, menu, switching, reconnecting, and scrolling up through 160 messages with two page loads and no jumps.

## Done: streaming replies (spec: `docs/streaming.md`)
✅ Confirmed on your iPhone and Hermes machine 2026-11-08 (after five rounds of your feedback). Built: replies appear word by word, with a "thinking…" line showing what the agent is doing ("Searching the web…"). Streaming is switched on for Lekora only, in memory (no Hermes config change, no command for you; other messaging apps keep their own setting); if a Hermes update breaks that, replies arrive whole as before. Finished replies are saved as normal messages, so history and replay are unchanged. Plugin 176 tests, app 79; real app checked against the real plugin over the encrypted connection. First phone test (2026-11-08): streaming works with your real Hermes. Your feedback fixed: blank lines around agent text trimmed and Markdown rendered (bold, links…); Hermes' own notices (restart, gateway online, background task) shown as small system lines instead of bubbles; the "Working — N min" heartbeat removed from the chat (the thinking line now shows "· 12 min"); status reads "Default is using…"; smooth iMessage-style dots. Second look (2026-11-08): two more fixed in the plugin. Tool-activity bubbles ("⚙️ tool_search…", Hindsight's memory tool) still showed for agents whose own Hermes settings ask for them; now hidden (the thinking line shows the same live). The "↪ Redirected current run" notice and its siblings are now system lines. Third look (2026-11-08): the Hindsight "recalled N memories" line is now a system line (plugin), and the empty gap that could appear above the message bar after a reply is fixed (app: the chat stays pinned to the bottom when content shrinks; checked in the simulator against the real plugin). Fourth look (2026-11-08): the chat still sometimes drifted up after a reply, and some new replies stayed out of view until you scrolled. Fixed in the app: the chat now follows the very bottom instead of jumping to a message, and only while you're at the bottom (reading older messages is never interrupted; sending always shows your message and the reply). Checked in the simulator with a keyboard-sized space under the message bar, over 7 messages of different lengths: no gap, no drift, every reply in view. Plugin 204 tests, app 84. Fifth look (2026-11-08): confirmed fixed.

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
- Known limits (by design, documented in the specs): agent routing uses Hermes internals (re-check after Hermes upgrades; the plugin falls back to Default-only if they change); agent display names come from their IDs.
