import SwiftUI

/// Chat Settings: what applies to this chat, what applies to every chat with the agent,
/// and actions (docs/chat-settings.md). Opened by tapping the agent at the top of a chat.
/// Changes go to Hermes as its own commands; Hermes' short reply shows in the chat.
struct ChatSettingsView: View {
    @ObservedObject var gateway: GatewayClient
    let profileId: String
    let agentName: String
    @Environment(\.dismiss) private var dismiss
    @State private var failure: String?
    @State private var confirmingYolo = false
    @State private var confirmingApprovalsOff = false
    @State private var confirmingNewChat = false
    @State private var confirmingUndo = false
    @State private var renaming = false
    @State private var newTitle = ""

    static let reasoningLevels: [(value: String, title: String)] = [
        ("none", "Off"), ("minimal", "Minimal"), ("low", "Low"), ("medium", "Medium"),
        ("high", "High"), ("xhigh", "Extra High"),
    ]
    static let approvalModes: [(value: String, title: String)] = [
        ("manual", "Ask Me"), ("smart", "Smart (Hermes decides)"), ("off", "Never Ask"),
    ]

    private var settings: ChatSettingsData? { gateway.chatSettings[profileId] }

    var body: some View {
        NavigationStack {
            Form {
                summary
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                if let failure {
                    Text(failure).font(LK.Typography.footnote).foregroundStyle(LK.Palette.danger)
                }
                thisChat
                wholeAgent
                actions
            }
            .navigationTitle("Chat Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { await gateway.loadSettings(for: profileId) }
            .refreshable { await gateway.loadSettings(for: profileId) }
            .alert("Turn on auto-approve?", isPresented: $confirmingYolo) {
                Button("Turn On", role: .destructive) { change("yolo", .flag(true)) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("\(agentName) will run risky commands in this chat without asking you first, such as deleting files or running scripts. You can turn it off any time.")
            }
            .alert("Never ask for approval?", isPresented: $confirmingApprovalsOff) {
                Button("Never Ask", role: .destructive) { change("approvals", .text("off")) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("\(agentName) will run risky commands without asking, in every chat with it.")
            }
            .alert("Start a new chat?", isPresented: $confirmingNewChat) {
                Button("New Chat", role: .destructive) { act("new") }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("\(agentName) starts fresh and forgets this conversation (it stays in your history here).")
            }
            .alert("Undo the last turn?", isPresented: $confirmingUndo) {
                Button("Undo", role: .destructive) { act("undo") }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removes your last message and \(agentName)'s reply from what it remembers.")
            }
            .alert("Rename this chat", isPresented: $renaming) {
                TextField("Name", text: $newTitle)
                Button("Save") { change("title", .text(newTitle)) }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    // MARK: - Summary

    private var summary: some View {
        VStack(alignment: .leading, spacing: LK.Spacing.md) {
            HStack(spacing: LK.Spacing.md) {
                LKAgentAvatar(id: profileId, palette: gateway.avatarPalettes[profileId], size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(agentName).font(.title3.weight(.bold))
                    Button {
                        newTitle = settings?.title ?? ""
                        renaming = true
                    } label: {
                        HStack(spacing: 4) {
                            Text(settings?.title ?? "Untitled chat")
                            Image(systemName: "pencil").font(.caption)
                        }
                        .font(LK.Typography.subheadline)
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Rename chat")
                }
                Spacer()
                if settings?.runsWithoutAsking == true { LKAutoApproveBadge() }
            }
            HStack(alignment: .top, spacing: LK.Spacing.sm) {
                tile("Model", shortModel ?? "—",
                     settings?.model.map { $0.this_chat == true ? "this session" : "default" } ?? "")
                tile("Context", contextUsed ?? "—", contextOf ?? "")
                tile("Cost", cost ?? "—", "this session")
            }
        }
        .padding(LK.Spacing.lg)
        .background(LK.Palette.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: LK.Radius.card, style: .continuous))
    }

    private var shortModel: String? {
        settings?.model?.model.components(separatedBy: "/").last
    }

    private var contextUsed: String? {
        guard let used = settings?.usage?.context_tokens, let total = settings?.usage?.context_length, total > 0 else { return nil }
        return "\(Int((Double(used) / Double(total) * 100).rounded()))%"
    }

    private var contextOf: String? {
        settings?.usage?.context_length.flatMap { LKModelText.context($0) }.map { "of \($0)" }
    }

    private var cost: String? {
        guard let usd = settings?.usage?.cost_usd else { return nil }
        return usd < 0.01 ? (usd == 0 ? "$0" : "<$0.01") : String(format: "$%.2f", usd)
    }

    private func tile(_ title: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold).monospacedDigit())
                .lineLimit(2).minimumScaleFactor(0.85).fixedSize(horizontal: false, vertical: true)
            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(LK.Spacing.sm)
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: LK.Radius.small, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    // MARK: - This chat

    private var thisChat: some View {
        Section {
            Button {
                dismiss()
                Task { await gateway.openModelPicker() }
            } label: {
                LabeledContent("Model") {
                    HStack(spacing: 4) {
                        Text(shortModel ?? "Unknown").lineLimit(1)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                }
            }
            .foregroundStyle(.primary)

            if let reasoning = settings?.reasoning {
                Picker("Reasoning", selection: Binding(get: { reasoning.effort },
                                                       set: { change("reasoning", .text($0)) })) {
                    ForEach(Self.reasoningLevels, id: \.value) { Text($0.title).tag($0.value) }
                    if !Self.reasoningLevels.contains(where: { $0.value == reasoning.effort }) {
                        Text(reasoning.effort.capitalized).tag(reasoning.effort)
                    }
                }
            } else {
                unknown("Reasoning")
            }

            if let fast = settings?.fast {
                Toggle("Fast Mode", isOn: Binding(get: { fast != "normal" },
                                                  set: { change("fast", .text($0 ? "fast" : "normal")) }))
            } else {
                unknown("Fast Mode")
            }

            if let yolo = settings?.yolo {
                Toggle(isOn: Binding(get: { yolo }, set: { on in
                    if on { confirmingYolo = true } else { change("yolo", .flag(false)) }
                })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-Approve")
                        Text("Runs risky commands without asking you.")
                            .font(LK.Typography.footnote)
                            .foregroundStyle(yolo ? LK.Palette.warning : .secondary)
                    }
                }
                .tint(LK.Palette.warning)
            } else {
                unknown("Auto-Approve")
            }
        } header: {
            Text("This Session Only")
        } footer: {
            Text("Reasoning and fast mode go back to the default when Hermes restarts.")
        }
    }

    // MARK: - Every chat with the agent

    private var wholeAgent: some View {
        Section {
            if let personality = settings?.personality {
                Picker("Personality", selection: Binding(get: { personality.current },
                                                         set: { change("personality", .text($0)) })) {
                    Text("None").tag("none")
                    ForEach(personality.options, id: \.name) { Text($0.name.capitalized).tag($0.name) }
                }
            } else {
                unknown("Personality")
            }

            if let approvals = settings?.approvals {
                Picker("Approvals", selection: Binding(get: { approvals }, set: { mode in
                    if mode == "off" { confirmingApprovalsOff = true } else { change("approvals", .text(mode)) }
                })) {
                    ForEach(Self.approvalModes, id: \.value) { Text($0.title).tag($0.value) }
                }
            } else {
                unknown("Approvals")
            }

            if let show = settings?.show_reasoning {
                Toggle("Show Reasoning", isOn: Binding(get: { show }, set: { change("show_reasoning", .flag($0)) }))
            } else {
                unknown("Show Reasoning")
            }
        } header: {
            Text("All of \(agentName)'s Chats")
        } footer: {
            Text("Saved in \(agentName)'s Hermes settings. Other agents keep their own.")
        }
    }

    // MARK: - Actions

    private var actions: some View {
        Section("Actions") {
            Button("New Chat", systemImage: "square.and.pencil") { confirmingNewChat = true }
            Button("Compress Conversation", systemImage: "arrow.down.right.and.arrow.up.left") { act("compress") }
            Button("Retry Last Message", systemImage: "arrow.clockwise") { act("retry") }
            Button("Undo Last Turn", systemImage: "arrow.uturn.backward", role: .destructive) { confirmingUndo = true }
        }
    }

    private func unknown(_ title: String) -> some View {
        LabeledContent(title) { Text("Unknown").foregroundStyle(.secondary) }
    }

    private func change(_ key: String, _ value: SettingValue) {
        failure = nil
        Task {
            do {
                try await gateway.changeSetting(key, to: value, in: profileId)
            } catch {
                failure = "Couldn't change that: \(error.localizedDescription)"
            }
        }
    }

    private func act(_ action: String) {
        failure = nil
        Task {
            do {
                try await gateway.runChatAction(action, in: profileId)
                dismiss()  // Hermes answers in the chat (New Chat asks to confirm there)
            } catch {
                failure = "Couldn't do that: \(error.localizedDescription)"
            }
        }
    }
}

/// The amber "Auto-approve" badge: the agent runs risky commands without asking.
struct LKAutoApproveBadge: View {
    var compact = false

    var body: some View {
        // An HStack, not a Label: in the navigation bar a Label shrinks to its icon.
        HStack(spacing: 3) {
            Image(systemName: "bolt.shield.fill")
            Text(compact ? "Auto" : "Auto-approve")
        }
        .font(.caption2.weight(.semibold))
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(LK.Palette.warning.opacity(0.18), in: Capsule())
        .foregroundStyle(LK.Palette.warning)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Auto-approve is on: risky commands run without asking")
    }
}

/// The agent at the top of a chat: avatar, name, model and the amber badge. Its own view
/// so the navigation bar redraws it whenever the chat's settings change.
struct ChatHeaderTitle: View {
    @ObservedObject var gateway: GatewayClient
    let profileName: String
    /// The computer it's on, once there are several.
    let computer: String?
    /// What's happening while not connected; nil = connected (shows the model).
    let connection: String?
    let working: Bool

    private var subtitle: String? {
        let detail = connection ?? gateway.chatSettings[gateway.activeProfileId]?.model?.model.components(separatedBy: "/").last
        guard let computer else { return detail }
        return detail.map { "\(computer) · \($0)" } ?? computer
    }

    private var runsWithoutAsking: Bool {
        gateway.chatSettings[gateway.activeProfileId]?.runsWithoutAsking == true
    }

    var body: some View {
        HStack(spacing: LK.Spacing.sm) {
            LKAgentAvatar(id: gateway.activeProfileId, palette: gateway.avatarPalettes[gateway.activeProfileId],
                          size: 28, working: working)
            VStack(alignment: .leading, spacing: 0) {
                Text(profileName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                HStack(spacing: 4) {
                    if runsWithoutAsking { LKAutoApproveBadge(compact: true) }
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(runsWithoutAsking ? "Auto-approve is on" : "")
    }
}
