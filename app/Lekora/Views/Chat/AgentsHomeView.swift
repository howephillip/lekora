import SwiftUI

/// Home: your agents, like conversations in Messages; tap one to open its chat
/// (docs/agents-home.md). With several computers, every computer's agents are here,
/// newest conversation first or grouped by computer (docs/multiple-instances.md).
public struct AgentsHomeView: View {
    /// How the list is arranged once there are several computers.
    public enum Layout: String {
        case recent
        case byComputer
    }

    @ObservedObject public var hosts: HostsModel
    @State private var path: [AgentKey] = []
    /// The computer an agent is being added to / whose agents are being managed.
    @State private var addingAgentOn: GatewayClient?
    @State private var newGroupOn: GatewayClient?
    @State private var managingAgentsOn: GatewayClient?
    @State private var showingComputers = false
    @State private var editingName = false
    /// The left menu (docs/kanban.md), and the board opened from it.
    @State private var menuOpen = false
    @State private var boardOn: GatewayClient?
    @State private var schedulesOn: GatewayClient?
    @AppStorage("homeLayout") private var layoutChoice = Layout.recent.rawValue

    public init(hosts: HostsModel) {
        self.hosts = hosts
    }

    private var layout: Layout {
        hosts.hasSeveral ? Layout(rawValue: layoutChoice) ?? .recent : .recent
    }

    private func isConnected(_ client: GatewayClient) -> Bool {
        if case .connected = client.state { return true }
        return false
    }

    private func name(of client: GatewayClient) -> String {
        client.savedHost?.instanceName ?? "Hermes"
    }

    /// Not connected and not trying right now (dropped, or couldn't be reached).
    private func isDown(_ client: GatewayClient) -> Bool {
        switch client.state {
        case .disconnected, .error: return true
        default: return false
        }
    }

    /// Only while something isn't connected: what's happening ("Connecting…").
    private var subtitle: String {
        let offline = hosts.clients.filter { !isConnected($0) }
        guard let first = offline.first else { return "" }
        if !hosts.hasSeveral { return isDown(first) ? "Not connected" : "Connecting…" }
        if layout == .byComputer { return "" }  // each section says it
        if offline.count == 1 {
            return isDown(first) ? "\(name(of: first)) not connected" : "Connecting to \(name(of: first))…"
        }
        return offline.allSatisfy(isDown) ? "\(offline.count) instances not connected" : "Connecting…"
    }

    private var connectedClients: [GatewayClient] {
        hosts.clients.filter(isConnected)
    }

    public var body: some View {
        let home = NavigationStack(path: $path) {
            withSheets(agentList
                .toolbar { homeToolbar }
                .navigationDestination(isPresented: Binding(get: { boardOn != nil }, set: { if !$0 { boardOn = nil; menuOpen = true } })) {
                    if let client = boardOn { BoardView(gateway: client) }
                }
                .navigationDestination(isPresented: Binding(get: { schedulesOn != nil }, set: { if !$0 { schedulesOn = nil; menuOpen = true } })) {
                    if let client = schedulesOn { SchedulesView(gateway: client) }
                }
                .navigationDestination(for: AgentKey.self) { key in
                    chat(for: key)
                })
        }
        // The left menu covers the whole screen, bars included.
        .overlay {
            SideMenuView(hosts: hosts, isOpen: $menuOpen,
                         openBoard: { boardOn = $0 },
                         openSchedules: { schedulesOn = $0 },
                         openYourName: { editingName = true },
                         openInstances: { showingComputers = true },
                         manageAgents: { managingAgentsOn = $0 })
        }
        return keepingConnected(home)
    }

    private func withSheets<V: View>(_ content: V) -> some View {
        content
            .sheet(item: $addingAgentOn) { client in
                AddAgentView(gateway: client, instanceName: name(of: client)) { created in
                    // The new agent is switched on and becomes the current chat.
                    if let id = client.savedHost?.instanceId {
                        path = [AgentKey(instanceId: id, profileId: created.profile_id)]
                    }
                }
            }
            .sheet(item: $newGroupOn) { client in
                GroupEditorView(gateway: client, group: nil) { made in
                    if let id = client.savedHost?.instanceId {
                        client.switchToProfile(made.key)
                        path = [AgentKey(instanceId: id, profileId: made.key)]
                    }
                }
            }
            .sheet(item: $managingAgentsOn) { client in
                ChooseProfilesView(gateway: client, mode: .edit)
            }
            .sheet(isPresented: $showingComputers) {
                ComputersView(hosts: hosts)
            }
            .sheet(isPresented: $editingName) {
                YourNameView(hosts: hosts)
            }
            // A computer just paired (e.g. from a link) whose agents haven't been chosen yet.
            // "Add Hermes Instance" shows this itself.
            .sheet(item: Binding(get: { showingComputers ? nil : hosts.clients.first { $0.needsProfileChoice } },
                                 set: { _ in })) { client in
                ChooseProfilesView(gateway: client, mode: .setup)
                    .interactiveDismissDisabled()
            }
    }

    private var agentList: some View {
            List {
                switch layout {
                case .recent:
                    // Group chats first (docs/group-chats.md), then every agent by recency.
                    ForEach(hosts.clients, id: \.savedHost?.instanceId) { client in
                        groupButtons(on: client)
                    }
                    ForEach(hosts.agentsByRecency, id: \.key) { item in
                        agentButton(item.key, client: item.client, profile: item.profile)
                    }
                case .byComputer:
                    ForEach(hosts.clients, id: \.savedHost?.instanceId) { client in
                        Section {
                            groupButtons(on: client)
                            ForEach(client.agentsByRecency) { profile in
                                agentButton(AgentKey(instanceId: client.savedHost?.instanceId ?? "", profileId: profile.profile_id),
                                            client: client, profile: profile)
                            }
                        } header: {
                            ComputerSectionHeader(gateway: client)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .lkScreenBackground()
            .navigationTitle("Agents")
            .navigationSubtitle(subtitle)
    }

    @ToolbarContentBuilder
    private var homeToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { menuOpen = true } label: { Label("Menu", systemImage: "line.3.horizontal") }
        }
        ToolbarItem(placement: .primaryAction) { addAgentButton }
        if hosts.hasSeveral {
            ToolbarItem(placement: .primaryAction) { moreMenu }
        }
    }

    @ViewBuilder
    private func chat(for key: AgentKey) -> some View {
        if let client = hosts.client(for: key.instanceId) {
            WalkingSkeletonPingView(gateway: client, instanceName: name(of: client),
                                    profileName: client.group(for: key.profileId)?.name
                                        ?? client.profiles.first { $0.profile_id == key.profileId }?.name ?? "",
                                    unreadElsewhere: unreadElsewhere(than: client),
                                    computerName: hosts.hasSeveral ? name(of: client) : nil,
                                    openChat: { chat in path = [AgentKey(instanceId: key.instanceId, profileId: chat)] })
                .onAppear { client.switchToProfile(key.profileId) }
        }
    }

    private func keepingConnected<V: View>(_ content: V) -> some View {
        content
        // An open chat whose agent was switched off or deleted, or whose computer was
        // forgotten, closes.
        .onChange(of: openableKeys) { _, keys in
            if let open = path.last, !keys.contains(open) { path = [] }
        }
        // A computer that couldn't be reached: try again now and then (the others keep working).
        .task {
            // Stops as soon as the list goes away: a cancelled sleep must never retry (with one
            // computer, a failed attempt swaps this list for the "Not connected" screen, and
            // retrying then brought it straight back: a reconnect loop).
            while (try? await Task.sleep(nanoseconds: 5_000_000_000)) != nil, !Task.isCancelled {
                for client in hosts.clients where client.retryDue {
                    if case .error = client.state { Task { await client.resumeSavedSession() } }
                }
            }
        }
        // Shown offline with the last known chats: try to reconnect after a dropped connection.
        .task(id: disconnectedIds) {
            guard !disconnectedIds.isEmpty else { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            // Their own tasks: this one is cancelled as soon as a state changes to
            // "connecting", which must not cancel the connection attempts themselves.
            for client in hosts.clients where client.state == .disconnected {
                Task { await client.resumeSavedSession() }
            }
        }
    }

    // MARK: - Toolbar

    @ViewBuilder
    private var addAgentButton: some View {
        if hosts.hasSeveral {
            Menu {
                Section("Add an Agent On") {
                    ForEach(hosts.clients, id: \.savedHost?.instanceId) { client in
                        Button(name(of: client)) { addingAgentOn = client }
                            .disabled(!isConnected(client))
                    }
                }
                Section("New Group On") {
                    ForEach(hosts.clients, id: \.savedHost?.instanceId) { client in
                        Button(name(of: client)) { newGroupOn = client }
                            .disabled(!isConnected(client) || client.profiles.count < 2)
                    }
                }
            } label: {
                Label("Add", systemImage: "plus")
            }
            .disabled(connectedClients.isEmpty)
        } else {
            Menu {
                Button("Add Agent", systemImage: "person.badge.plus") { addingAgentOn = hosts.clients.first }
                Button("New Group", systemImage: "person.3") { newGroupOn = hosts.clients.first }
                    .disabled((hosts.clients.first?.profiles.count ?? 0) < 2)
            } label: {
                Label("Add", systemImage: "plus")
            }
            .disabled(connectedClients.isEmpty)
        }
    }

    /// Several instances: how the list is arranged (settings are in the left menu).
    private var moreMenu: some View {
        Menu {
            Picker("Arrange", selection: $layoutChoice) {
                Text("Sort by Recent").tag(Layout.recent.rawValue)
                Text("Group by Instance").tag(Layout.byComputer.rawValue)
            }
            .pickerStyle(.inline)
        } label: {
            Label("Arrange", systemImage: "line.3.horizontal.decrease")
        }
    }

    // MARK: - Rows

    private func agentButton(_ key: AgentKey, client: GatewayClient, profile: ProfileData) -> some View {
        Button {
            open(key, on: client)
        } label: {
            LKAgentRow(row(for: profile, on: client))
        }
        .buttonStyle(.plain)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: LK.Spacing.xs, leading: LK.Spacing.sm,
                                  bottom: LK.Spacing.xs, trailing: LK.Spacing.lg))
    }

    /// A host's group chats, as rows (docs/group-chats.md).
    @ViewBuilder
    private func groupButtons(on client: GatewayClient) -> some View {
        ForEach(client.groups) { group in
            let key = AgentKey(instanceId: client.savedHost?.instanceId ?? "", profileId: group.key)
            Button {
                open(key, on: client)
            } label: {
                LKAgentRow(groupRow(group, on: client))
            }
            .buttonStyle(.plain)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: LK.Spacing.xs, leading: LK.Spacing.sm,
                                      bottom: LK.Spacing.xs, trailing: LK.Spacing.lg))
        }
    }

    private func groupRow(_ group: GroupData, on gateway: GatewayClient) -> LKAgentRow.Content {
        let last = gateway.timeline.entries(for: group.key).last { $0.role != .system }
        var preview: String
        if let last {
            preview = LKChatText.preview(last.text)
            if preview.isEmpty, let files = last.files { preview = LKFileText.preview(files) }
            if last.role == .user {
                preview = "You: " + preview
            } else if let speaker = last.speaker {
                preview = gateway.agentName(speaker) + ": " + preview
            }
        } else {
            preview = group.members.map(gateway.agentName).joined(separator: ", ")
        }
        let working = gateway.agentActivity[group.key].map { Self.workingLine($0.status) }
        let computer = hosts.hasSeveral && layout == .recent ? name(of: gateway) : nil
        return LKAgentRow.Content(id: group.key, name: group.name, preview: preview, date: last?.date,
                                  unread: gateway.hasUnread(group.key), working: working,
                                  attention: gateway.openPrompt(for: group.key).map(LKPromptText.attention(for:)),
                                  computer: computer, members: group.members, memberPalettes: gateway.avatarPalettes)
    }

    private func open(_ key: AgentKey, on client: GatewayClient) {
        client.switchToProfile(key.profileId)
        path = [key]
    }

    /// Every agent that can be open: the ones each computer uses.
    private var openableKeys: Set<AgentKey> {
        Set(hosts.clients.flatMap { client in
            client.enabledProfiles.map { AgentKey(instanceId: client.savedHost?.instanceId ?? "", profileId: $0.profile_id) }
                + client.groups.map { AgentKey(instanceId: client.savedHost?.instanceId ?? "", profileId: $0.key) }
        })
    }

    private var disconnectedIds: [String] {
        hosts.clients.filter { $0.state == .disconnected }.compactMap { $0.savedHost?.instanceId }
    }

    /// Agents with unread replies on the other computers (the chat's back-button count).
    private func unreadElsewhere(than client: GatewayClient) -> Int {
        hosts.clients.filter { $0 !== client }.reduce(0) { total, other in
            total + other.enabledProfiles.filter { other.hasUnread($0.profile_id) }.count
        }
    }

    private func row(for profile: ProfileData, on gateway: GatewayClient) -> LKAgentRow.Content {
        let id = profile.profile_id
        let last = gateway.timeline.entries(for: id).last { $0.role != .system }
        var preview: String
        if let last {
            preview = LKChatText.preview(last.text)
            if last.voice != nil {
                preview = "Voice note" + (last.transcript.map { ": " + $0 } ?? "")
            } else if preview.isEmpty, let files = last.files {
                preview = LKFileText.preview(files)
            }
            if last.role == .user { preview = "You: " + preview }
        } else {
            preview = profile.description.map { "No messages yet · \($0)" } ?? "No messages yet"
        }
        var working: String?
        if let activity = gateway.agentActivity[id] {
            working = Self.workingLine(activity.status)
        }
        let attention = gateway.openPrompt(for: id).map(LKPromptText.attention(for:))
        // The computer's name only where it tells agents apart: several computers, one list.
        let computer = hosts.hasSeveral && layout == .recent ? name(of: gateway) : nil
        return LKAgentRow.Content(id: id, palette: gateway.avatarPalettes[id], name: profile.name, preview: preview, date: last?.date,
                                  unread: gateway.hasUnread(id), working: working, attention: attention, computer: computer)
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

extension GatewayClient: Identifiable {
    public nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
}

/// A Hermes instance's heading in "Group by Instance": its name, and whether it's connected.
private struct ComputerSectionHeader: View {
    @ObservedObject var gateway: GatewayClient

    private var status: String? {
        switch gateway.state {
        case .connected: return nil
        case .disconnected, .error: return "Not connected"
        default: return "Connecting…"
        }
    }

    var body: some View {
        HStack(spacing: LK.Spacing.sm) {
            Image(systemName: "server.rack")
            Text(gateway.savedHost?.instanceName ?? "Hermes")
            if let status {
                Text("· \(status)").foregroundStyle(.secondary)
            }
        }
        .font(LK.Typography.subheadline.weight(.semibold))
        .textCase(nil)
        .accessibilityElement(children: .combine)
    }
}
