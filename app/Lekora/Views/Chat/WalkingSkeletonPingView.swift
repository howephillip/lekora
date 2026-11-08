import SwiftUI

/// The connected screen: a chat with the active agent. Tap the title to switch agents.
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
    @State private var confirmingForget = false
    @State private var choosingAgents = false
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

    private var isDisconnected: Bool { gateway.state == .disconnected }

    /// The host's name, or what's happening while the last known chats are shown offline.
    private var subtitle: String {
        if isConnected { return instanceName }
        return isDisconnected ? "Not connected" : "Connecting…"
    }

    public var body: some View {
        NavigationStack {
            messageList
                .lkScreenBackground()
                .safeAreaBar(edge: .bottom) {
                    LKComposer("Message \(profileName)", text: $draft, canSend: canSend,
                               focus: $inputFocused, onSend: send)
                }
                .navigationTitle(profileName)
                .navigationSubtitle(subtitle)
                // A blue dot when another agent has replies waiting (docs/chat-history.md).
                #if os(iOS)
                .toolbar {
                    ToolbarItem(placement: .title) {
                        titleView
                    }
                }
                #endif
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                // Agent switcher: tapping the title opens this menu (the system adds the chevron).
                .toolbarTitleMenu {
                    ForEach(gateway.enabledProfiles) { profile in
                        Button {
                            gateway.switchToProfile(profile.profile_id)
                        } label: {
                            if profile.profile_id == gateway.activeProfileId {
                                Label(profile.name, systemImage: "checkmark")
                            } else if gateway.hasUnread(profile.profile_id) {
                                // Title, subtitle and icon: the menu row layout.
                                Text(profile.name)
                                Text("New messages")
                                LKUnreadDot.menuIcon
                            } else {
                                Text(profile.name)
                            }
                        }
                    }
                    Divider()
                    Button("Manage Agents…", systemImage: "person.2") {
                        choosingAgents = true
                    }
                }
                .sheet(isPresented: $choosingAgents) {
                    ChooseProfilesView(gateway: gateway, mode: .edit)
                }
                // No "connected" badge: this screen only shows while connected; any
                // connection problem switches the app to the Reconnecting screen.
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button("Forget Host", systemImage: "xmark.circle", role: .destructive) {
                                confirmingForget = true
                            }
                        } label: {
                            Label("More", systemImage: "ellipsis")
                        }
                    }
                }
                .confirmationDialog(
                    "Forget \(instanceName)?",
                    isPresented: $confirmingForget,
                    titleVisibility: .visible
                ) {
                    Button("Disconnect and Forget", role: .destructive) {
                        Task { await gateway.forgetHost() }
                    }
                } message: {
                    Text("This phone will disconnect and be removed from the host's device list. To connect again you'll need a new pairing code from the Hermes machine. Your chats stay on the host.")
                }
                .overlay {
                    if gateway.isForgetting {
                        LKBlockingProgress("Forgetting host…")
                    }
                }
        }
        // New messages count as read only while the chat is on screen with the app in front.
        .onAppear { isOnScreen = true; updateVisibility() }
        .onDisappear { isOnScreen = false; updateVisibility() }
        .onChange(of: scenePhase) { _, _ in updateVisibility() }
        // Shown offline with the last known chats: try to reconnect after a dropped connection.
        .task(id: isDisconnected) {
            guard isDisconnected else { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            // Its own task: this one is cancelled as soon as the state changes to
            // "connecting", which must not cancel the connection attempt itself.
            Task { await gateway.resumeSavedSession() }
        }
    }

    private func updateVisibility() {
        gateway.setChatVisible(isOnScreen && scenePhase == .active)
    }

    /// The agent's name, with a blue dot when another agent has unread replies. The system
    /// adds the subtitle and the menu chevron; tapping it opens the agent menu.
    private var titleView: some View {
        HStack(spacing: 6) {
            Text(profileName)
                .font(.headline)
                .lineLimit(1)
            if gateway.otherAgentsHaveUnread {
                LKUnreadDot()
                    .accessibilityLabel("Another agent has new messages")
            }
        }
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
                ForEach(messages) { entry in
                    Group {
                        if entry.role == .system {
                            LKSystemNotice(entry.text)
                        } else {
                            LKMessageBubble(entry.text, from: entry.role == .user ? .user : .agent,
                                            delivery: delivery(for: entry))
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
        isAtBottom = true          // you just sent something: show it, and the reply
        scrollToBottom(animated: true)
        Task {
            await gateway.sendMessage(text)
        }
    }
}
