import SwiftUI

/// The connected screen: a chat with the active profile.
public struct WalkingSkeletonPingView: View {
    @ObservedObject public var gateway: GatewayClient
    public let instanceName: String
    public let profileName: String

    @State private var draft: String = ""
    @FocusState private var inputFocused: Bool
    @State private var confirmingForget = false

    public init(gateway: GatewayClient, instanceName: String, profileName: String) {
        self.gateway = gateway
        self.instanceName = instanceName
        self.profileName = profileName
    }

    private var messages: [ChatEntry] {
        gateway.timeline.entries(for: gateway.activeProfileId)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isConnected: Bool {
        if case .connected = gateway.state { return true }
        return false
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Divider()
                messageList
            }
            .safeAreaInset(edge: .bottom) {
                inputBar
            }
            .navigationTitle(profileName)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Forget Host", role: .destructive) {
                        confirmingForget = true
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
                    ForgettingOverlay()
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(isConnected ? Color.green : Color.orange)
                .frame(width: 10, height: 10)
                .accessibilityLabel(isConnected ? "Connected" : "Not connected")

            VStack(alignment: .leading, spacing: 2) {
                Text(instanceName)
                    .font(.headline)
                Text("Active Agent: \(profileName)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer()

            Text("Seq #\(gateway.currentSeq)")
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.15))
                .cornerRadius(6)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    // MARK: - Messages

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    if messages.isEmpty {
                        Text("Send a message to \(profileName) to start the conversation.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.top, 40)
                            .padding(.horizontal, 32)
                    }
                    ForEach(messages) { entry in
                        MessageBubble(entry: entry)
                            .id(entry.id)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            }
            .defaultScrollAnchor(.bottom)
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

    private func scrollToNewest(_ id: String?, proxy: ScrollViewProxy) {
        guard let id else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(id, anchor: .bottom)
        }
    }

    // MARK: - Input

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message \(profileName)", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($inputFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 18))

            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
            }
            .disabled(!canSend || !isConnected)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
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

/// A single chat bubble: the user's on the right, the agent's on the left.
struct MessageBubble: View {
    let entry: ChatEntry

    private var isUser: Bool { entry.role == .user }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 48) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                Text(entry.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .foregroundColor(isUser ? .white : .primary)
                    .background(isUser ? Color.blue : Color.secondary.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .opacity(entry.status == .sending ? 0.6 : 1)

                switch entry.status {
                case .sending:
                    Text("Sending…")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                case .failed(let reason):
                    Label("Not delivered: \(reason)", systemImage: "exclamationmark.circle")
                        .font(.caption2)
                        .foregroundColor(.red)
                case .sent:
                    EmptyView()
                }
            }

            if !isUser { Spacer(minLength: 48) }
        }
    }
}
