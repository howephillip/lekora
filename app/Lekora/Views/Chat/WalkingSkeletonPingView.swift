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

    public init(gateway: GatewayClient, instanceName: String, profileName: String) {
        self.gateway = gateway
        self.instanceName = instanceName
        self.fallbackProfileName = profileName
    }

    private var messages: [ChatEntry] {
        gateway.timeline.entries(for: gateway.activeProfileId)
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
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: LK.Spacing.sm) {
                    if messages.isEmpty {
                        emptyState
                    }
                    ForEach(messages) { entry in
                        LKMessageBubble(entry.text, from: entry.role == .user ? .user : .agent,
                                        delivery: delivery(for: entry))
                            .id(entry.id)
                    }
                }
                .padding(.horizontal, LK.Spacing.lg)
                .padding(.vertical, LK.Spacing.md)
            }
            .defaultScrollAnchor(.bottom)
            // A fresh list per agent, so switching opens that agent's chat at its newest message.
            .id(gateway.activeProfileId)
            #if os(iOS)
            .scrollDismissesKeyboard(.interactively)
            #endif
            .onChange(of: messages.last?.id) { _, newest in
                scrollToNewest(newest, proxy: proxy)
            }
            .onChange(of: inputFocused) { _, focused in
                // Keep the newest message visible when the keyboard slides up.
                if focused { scrollToNewest(messages.last?.id, proxy: proxy) }
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
        }
    }

    private func scrollToNewest(_ id: String?, proxy: ScrollViewProxy) {
        guard let id else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(id, anchor: .bottom)
        }
    }

    private func send() {
        guard canSend else { return }
        let text = draft
        draft = ""
        Task {
            await gateway.sendMessage(text)
        }
    }
}
