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

    public var body: some View {
        NavigationStack {
            messageList
                .lkScreenBackground()
                .safeAreaBar(edge: .bottom) {
                    LKComposer("Message \(profileName)", text: $draft, canSend: canSend,
                               focus: $inputFocused, onSend: send)
                }
                .navigationTitle(profileName)
                .navigationSubtitle(instanceName)
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
    }

    // MARK: - Messages

    private var messageList: some View {
        ScrollView {
            LazyVStack(spacing: LK.Spacing.sm) {
                if messages.isEmpty {
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

    /// Changes whenever the bottom of the chat changes.
    private var contentSignature: [Int] {
        [messages.count, messages.last?.text.count ?? 0, showsTypingIndicator ? 1 : 0,
         (statusText ?? "").count]
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
