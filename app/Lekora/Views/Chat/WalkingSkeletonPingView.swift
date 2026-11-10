import SwiftUI

/// A chat with one agent, opened from the agents list (docs/agents-home.md).
public struct WalkingSkeletonPingView: View {
    @ObservedObject public var gateway: GatewayClient
    public let instanceName: String
    /// Name to show until the active agent is known.
    private let fallbackProfileName: String

    private var profileName: String {
        gateway.activeProfile?.name ?? fallbackProfileName
    }

    @State private var draft: String = ""
    @FocusState private var inputFocused: Bool
    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    @State private var isAtBottom = true
    @State private var isOnScreen = false
    /// Whether the user is scrolling (dragging or coasting), as opposed to layout or code
    /// moving the list: only the user's scrolling loads older messages.
    @State private var userIsScrolling = false
    /// Set while a page of older messages loads and the list settles: no further loads,
    /// or the next page would start before this one is back in place.
    @State private var pageInFlight = false
    @Environment(\.scenePhase) private var scenePhase
    /// How far the messages are dragged left to show their times (as in Messages).
    @State private var timeReveal: CGFloat = 0
    private static let timeRevealWidth: CGFloat = 72
    @State private var restoredDraft = false
    /// Changed on every send: a fresh text box, so nothing the keyboard was still holding
    /// (an autocorrect or prediction) can write the sent text back into it.
    @State private var composerID = 0

    public init(gateway: GatewayClient, instanceName: String, profileName: String) {
        self.gateway = gateway
        self.instanceName = instanceName
        self.fallbackProfileName = profileName
    }

    private var messages: [ChatEntry] {
        gateway.timeline.entries(for: gateway.activeProfileId)
    }

    private var activity: AgentActivity? {
        gateway.agentActivity[gateway.activeProfileId]
    }

    /// Hermes' status phrases start with the verb ("is using browser_exec…"): put the
    /// agent's name in front.
    private var statusText: String? {
        guard let status = activity?.status?.trimmingCharacters(in: .whitespaces), !status.isEmpty else { return nil }
        if status.hasPrefix("is ") || status.hasPrefix("has ") {
            return "\(profileName) \(status)"
        }
        return status
    }

    /// Dots while the agent works. Hidden while its reply is already streaming in,
    /// unless Hermes says what it's doing (e.g. running a tool between messages).
    private var showsTypingIndicator: Bool {
        guard let activity else { return false }
        // Waiting for you to answer a card: the agent isn't working, and a disappearing
        // bubble would shift the card under your finger.
        if messages.last?.card?.isOpen() == true { return false }
        let streaming = messages.last?.status == .streaming
        return !streaming || !(activity.status ?? "").isEmpty
    }

    private var canSend: Bool {
        isConnected && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isConnected: Bool {
        if case .connected = gateway.state { return true }
        return false
    }

    /// Only while not connected: what's happening ("Connecting…").
    private var subtitle: String? {
        if isConnected { return nil }
        return gateway.state == .disconnected ? "Not connected" : "Connecting…"
    }

    public var body: some View {
        messageList
            // Scrolled up into older messages: a small button back to the newest one.
            .overlay(alignment: .bottomTrailing) {
                if !isAtBottom {
                    Button {
                        isAtBottom = true
                        scrollToBottom(animated: true)
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .padding(.trailing, LK.Spacing.lg)
                    .padding(.bottom, LK.Spacing.sm)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                    .accessibilityLabel("Newest message")
                }
            }
            .animation(.easeOut(duration: 0.2), value: isAtBottom)
            .lkScreenBackground()
            .safeAreaBar(edge: .bottom) {
                VStack(spacing: LK.Spacing.sm) {
                    // Typing "/": this agent's commands, from Hermes (docs/slash-commands.md).
                    let suggestions = LKCommandMatcher.suggestions(
                        for: draft, commands: gateway.commands[gateway.activeProfileId] ?? [])
                    if !suggestions.isEmpty {
                        LKCommandSuggestions(suggestions) { picked in
                            draft = picked.insert
                            inputFocused = true
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    LKComposer("Message \(profileName)", text: $draft, canSend: canSend,
                               focus: $inputFocused, onSend: send)
                        .id(composerID)
                }
                .animation(.easeOut(duration: 0.15), value: draft.hasPrefix("/"))
            }
            .navigationTitle(profileName)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Next to the standard back button (which keeps the swipe-back gestures):
                // how many other agents have unread replies — docs/agents-home.md.
                if gateway.otherAgentsWithUnread > 0 {
                    ToolbarItem(placement: .topBarLeading) {
                        unreadBadge
                    }
                }
                // Change this agent's model: opens Hermes' own model picker (as /model does).
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await gateway.openModelPicker() }
                    } label: {
                        Label("Model", systemImage: "cpu")
                    }
                    .disabled(!isConnected)
                }
                ToolbarItem(placement: .title) {
                    HStack(spacing: LK.Spacing.sm) {
                        LKAgentAvatar(id: gateway.activeProfileId, palette: gateway.avatarPalettes[gateway.activeProfileId],
                                      size: 28, working: activity != nil)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(profileName)
                                .font(.headline)
                            if let subtitle {
                                Text(subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .lineLimit(1)
                    }
                }
            }
            #endif
            // New messages count as read only while the chat is on screen with the app in front.
            .onAppear {
                isOnScreen = true
                updateVisibility()
                if !restoredDraft {  // once: a later onAppear must not bring back sent text
                    restoredDraft = true
                    draft = gateway.drafts[gateway.activeProfileId] ?? ""
                }
            }
            .onChange(of: draft) { _, text in
                gateway.drafts[gateway.activeProfileId] = text.isEmpty ? nil : text
            }
            // This agent's commands; again once connected, if the chat opened offline.
            .task(id: "\(gateway.activeProfileId)|\(isConnected)") {
                if isConnected { await gateway.loadCommands(for: gateway.activeProfileId) }
            }
            // Opened by a push: once it has slid in and the message bar is measured, show
            // the newest message in full.
            .task {
                try? await Task.sleep(nanoseconds: 400_000_000)
                isAtBottom = true
                scrollToBottom(animated: false)
            }
            .onDisappear { isOnScreen = false; updateVisibility() }
            .onChange(of: scenePhase) { _, _ in updateVisibility() }
    }

    private func updateVisibility() {
        gateway.setChatVisible(isOnScreen && scenePhase == .active)
    }

    private var unreadBadge: some View {
        Text("\(gateway.otherAgentsWithUnread)")
            .font(LK.Typography.captionStrong)
            .foregroundStyle(LK.Palette.onAccent)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(LK.Palette.accent, in: Capsule())
            .accessibilityLabel(gateway.otherAgentsWithUnread == 1
                                ? "1 other agent with new messages"
                                : "\(gateway.otherAgentsWithUnread) other agents with new messages")
    }

    // MARK: - Messages

    private var messageList: some View {
        ScrollView {
            LazyVStack(spacing: LK.Spacing.sm) {
                if gateway.canLoadOlder(gateway.activeProfileId) {
                    // Older messages are on the host; they load when scrolling up near here.
                    ProgressView()
                        .opacity(gateway.loadingOlder.contains(gateway.activeProfileId) ? 1 : 0)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, LK.Spacing.sm)
                } else if messages.isEmpty {
                    emptyState
                }
                let timeLines = LKTime.separatorIds(for: messages)
                ForEach(messages) { entry in
                    Group {
                        if timeLines.contains(entry.id), let date = entry.date {
                            LKTimeSeparator(date)
                        }
                        if entry.role == .system {
                            LKSystemNotice(entry.text)
                        } else if let card = entry.card {
                            LKPromptCard(card, agentName: profileName, actions: promptActions(for: card))
                        } else {
                            LKMessageBubble(entry.text, from: entry.role == .user ? .user : .agent,
                                            delivery: delivery(for: entry))
                                .offset(x: -timeReveal)
                                .overlay(alignment: .trailing) {
                                    if let date = entry.date {
                                        Text(date.formatted(date: .omitted, time: .shortened))
                                            .font(LK.Typography.caption)
                                            .foregroundStyle(.secondary)
                                            .fixedSize()
                                            .offset(x: Self.timeRevealWidth - timeReveal)
                                            .opacity(timeReveal / Self.timeRevealWidth)
                                            .accessibilityHidden(true)
                                    }
                                }
                        }
                    }
                    .id(entry.id)
                }
                if showsTypingIndicator {
                    LKTypingIndicator(status: statusText, since: activity?.since)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, LK.Spacing.lg)
            .padding(.vertical, LK.Spacing.md)
        }
        #if os(iOS)
        // Drag left to see every message's time; let go and they slide back (as in Messages).
        // Only leftward drags: swiping right still goes back to the agents list.
        .gesture(LKLeftwardPan(
            onChange: { distance in timeReveal = min(distance, Self.timeRevealWidth) },
            onEnd: { withAnimation(.spring(duration: 0.3)) { timeReveal = 0 } }))
        #endif
        .onScrollPhaseChange { _, phase in
            userIsScrolling = phase == .interacting || phase == .decelerating
        }
        // Follow the bottom EDGE, not a message id: the list measures bubbles lazily and
        // they change height while streaming, so scrolling to an id could stop short
        // (new reply out of view) or leave a gap above the message bar.
        .scrollPosition($scrollPosition)
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            // "At the bottom" = the visible area reaches the end of the content
            // (visibleRect already excludes the keyboard and message bar).
            geometry.visibleRect.maxY >= geometry.contentSize.height - Self.bottomSlack
        } action: { _, atBottom in
            isAtBottom = atBottom
        }
        .onScrollGeometryChange(for: TopEdge.self) { geometry in
            TopEdge(distance: geometry.visibleRect.minY,
                    fits: geometry.contentSize.height <= geometry.containerSize.height)
        } action: { old, new in
            // Scrolling up to the top, or a chat too short to scroll: fetch the page before.
            let reachedTop = userIsScrolling && new.distance < Self.loadOlderZone && new.distance < old.distance
            if reachedTop || new.fits {
                loadOlder()
            }
        }
        // A fresh list per agent, so switching opens that agent's chat at its newest message.
        .id(gateway.activeProfileId)
        #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
        .onChange(of: contentSignature) { _, _ in
            // New message, growing live reply, thinking bubble on/off: follow along, but
            // only if the reader is already at the bottom (never yank them out of history).
            if isAtBottom { scrollToBottom(animated: true) }
        }
        .animation(.easeOut(duration: 0.2), value: showsTypingIndicator)
        .onChange(of: inputFocused) { _, focused in
            // The keyboard shrinks the visible area: keep the newest message in view.
            if focused && isAtBottom { scrollToBottom(animated: true) }
        }
        .onChange(of: gateway.activeProfileId) { _, _ in
            isAtBottom = true
            scrollPosition = ScrollPosition(edge: .bottom)
        }
    }

    /// How far from the end still counts as "at the bottom".
    private static let bottomSlack: CGFloat = 80

    /// Changes whenever the bottom of the chat changes (not when older messages load above).
    private var contentSignature: String {
        "\(messages.last?.id ?? "")|\(messages.last?.text.count ?? 0)|\(showsTypingIndicator)|\((statusText ?? "").count)"
    }

    /// Where the top of the visible area is, and whether the whole chat fits on screen.
    private struct TopEdge: Equatable {
        var distance: CGFloat
        var fits: Bool
    }

    /// How close to the top scrolling up starts loading older messages.
    private static let loadOlderZone: CGFloat = 60

    /// Loads the page before the oldest message shown. The reader is at the top, so that
    /// message is put back at the top afterwards (the list would otherwise keep its distance
    /// from the top and jump to the new, older messages).
    private func loadOlder() {
        let profileId = gateway.activeProfileId
        guard !pageInFlight, gateway.canLoadOlder(profileId),
              !gateway.loadingOlder.contains(profileId) else { return }
        pageInFlight = true
        Task {
            guard let page = await gateway.fetchOlderPage(profileId) else {
                pageInFlight = false
                return
            }
            // iOS ignores moving the list while a finger is on it: add the page once the
            // drag (and any coasting) has ended.
            while userIsScrolling {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard profileId == gateway.activeProfileId else {
                pageInFlight = false
                return
            }
            let anchor = messages.first?.id
            let keepPlace = !isAtBottom
            gateway.applyOlderPage(page, for: profileId)
            DispatchQueue.main.async {
                if keepPlace, let anchor {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    // Through the list's own position, so it isn't later reset to the
                    // "at the top" it held while the reader was scrolling.
                    withTransaction(transaction) {
                        scrollPosition.scrollTo(id: anchor, anchor: .top)
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { pageInFlight = false }
            }
        }
    }

    private func scrollToBottom(animated: Bool) {
        // Wait one layout pass so the new content is measured before scrolling to the edge.
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.2)) { scrollPosition.scrollTo(edge: .bottom) }
            } else {
                scrollPosition.scrollTo(edge: .bottom)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: LK.Spacing.md) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: LK.Size.heroIcon))
                .foregroundStyle(LK.Palette.accent.gradient)
            Text("Say hello to \(profileName)")
                .font(LK.Typography.headline)
            Text("Messages you send here go to your agent on \(instanceName).")
                .font(LK.Typography.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 80)
        .padding(.horizontal, LK.Spacing.xxl)
    }

    /// Answers from a card go to the host, for this chat's agent (docs/prompts.md).
    private func promptActions(for card: PromptCard) -> LKPromptActions {
        let profileId = gateway.activeProfileId
        return LKPromptActions(
            approve: { choice, reason in
                try await gateway.answerApproval(card, in: profileId, choice: choice, reason: reason)
            },
            answer: { answers, text in
                try await gateway.answerQuestion(card, in: profileId, answers: answers, text: text)
            },
            pickModel: { model, provider, confirmed in
                try await gateway.pickModel(card, in: profileId, model: model, provider: provider, confirmed: confirmed)
            },
            models: LKModelSource(
                catalog: { provider, models in
                    try await gateway.modelCatalog(provider: provider, models: models, in: profileId).models
                },
                hosts: { model in try await gateway.modelHosts(model, in: profileId) },
                setRouting: { model, mode, hosts, noTraining in
                    try await gateway.setRouting(model, mode: mode, hosts: hosts, noTraining: noTraining, in: profileId)
                }))
    }

    private func delivery(for entry: ChatEntry) -> LKMessageBubble.Delivery {
        switch entry.status {
        case .sending: return .sending
        case .sent: return .delivered
        case .failed(let reason): return .failed(reason)
        case .streaming: return .streaming
        }
    }


    private func send() {
        guard canSend else { return }
        let text = draft
        draft = ""
        gateway.drafts[gateway.activeProfileId] = nil
        // A fresh text box (see composerID), keeping the keyboard up.
        composerID += 1
        DispatchQueue.main.async { inputFocused = true }
        isAtBottom = true          // you just sent something: show it, and the reply
        scrollToBottom(animated: true)
        Task {
            await gateway.sendMessage(text)
        }
    }
}
