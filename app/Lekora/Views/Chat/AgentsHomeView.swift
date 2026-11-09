import SwiftUI

/// Home: your agents, like conversations in Messages; tap one to open its chat
/// (docs/agents-home.md).
public struct AgentsHomeView: View {
    @ObservedObject public var gateway: GatewayClient
    @State private var path: [String] = []
    @State private var addingAgent = false
    @State private var managingAgents = false
    @State private var confirmingForget = false

    public init(gateway: GatewayClient) {
        self.gateway = gateway
    }

    private var instanceName: String {
        gateway.savedHost?.instanceName ?? "Hermes"
    }

    private var isDisconnected: Bool { gateway.state == .disconnected }

    /// Only while not connected: what's happening ("Connecting…").
    private var subtitle: String {
        if case .connected = gateway.state { return "" }
        return isDisconnected ? "Not connected" : "Connecting…"
    }

    public var body: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(gateway.agentsByRecency) { profile in
                    Button {
                        open(profile.profile_id)
                    } label: {
                        LKAgentRow(row(for: profile))
                    }
                    .buttonStyle(.plain)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: LK.Spacing.xs, leading: LK.Spacing.sm,
                                              bottom: LK.Spacing.xs, trailing: LK.Spacing.lg))
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .lkScreenBackground()
            .navigationTitle("Agents")
            .navigationSubtitle(subtitle)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        addingAgent = true
                    } label: {
                        Label("Add Agent", systemImage: "plus")
                    }
                    .disabled(!isConnected)
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Manage Agents…", systemImage: "person.2") {
                            managingAgents = true
                        }
                        Divider()
                        Button("Forget Host", systemImage: "xmark.circle", role: .destructive) {
                            confirmingForget = true
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                }
            }
            .navigationDestination(for: String.self) { profileId in
                WalkingSkeletonPingView(gateway: gateway, instanceName: instanceName,
                                        profileName: gateway.profiles.first { $0.profile_id == profileId }?.name ?? "")
                    .onAppear { gateway.switchToProfile(profileId) }
            }
            .sheet(isPresented: $addingAgent) {
                AddAgentView(gateway: gateway, instanceName: instanceName) { created in
                    // The new agent is switched on and becomes the current chat.
                    path = [created.profile_id]
                }
            }
            .sheet(isPresented: $managingAgents) {
                ChooseProfilesView(gateway: gateway, mode: .edit)
            }
            .confirmationDialog("Forget \(instanceName)?", isPresented: $confirmingForget, titleVisibility: .visible) {
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
        // An open chat whose agent was switched off or deleted closes.
        .onChange(of: gateway.enabledProfiles.map(\.profile_id)) { _, enabled in
            if let open = path.last, !enabled.contains(open) { path = [] }
        }
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

    private var isConnected: Bool {
        if case .connected = gateway.state { return true }
        return false
    }

    private func open(_ profileId: String) {
        gateway.switchToProfile(profileId)
        path = [profileId]
    }

    private func row(for profile: ProfileData) -> LKAgentRow.Content {
        let id = profile.profile_id
        let last = gateway.timeline.entries(for: id).last { $0.role != .system }
        var preview: String
        if let last {
            preview = LKChatText.preview(last.text)
            if last.role == .user { preview = "You: " + preview }
        } else {
            preview = profile.description.map { "No messages yet · \($0)" } ?? "No messages yet"
        }
        var working: String?
        if let activity = gateway.agentActivity[id] {
            working = Self.workingLine(activity.status)
        }
        return LKAgentRow.Content(id: id, palette: gateway.avatarPalettes[id], name: profile.name, preview: preview, date: last?.date,
                                  unread: gateway.hasUnread(id), working: working)
    }

    /// "is searching the web…" -> "Searching the web…"; nothing said -> "Thinking…".
    static func workingLine(_ status: String?) -> String {
        guard var line = status?.trimmingCharacters(in: .whitespaces), !line.isEmpty else { return "Thinking…" }
        for prefix in ["is ", "has "] where line.hasPrefix(prefix) {
            line.removeFirst(prefix.count)
        }
        return line.prefix(1).uppercased() + line.dropFirst()
    }
}
