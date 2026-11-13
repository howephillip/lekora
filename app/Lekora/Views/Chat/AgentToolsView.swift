import SwiftUI

/// The tools an agent has in Lekora chats (docs/agent-tools.md). Lekora chats are their own
/// Hermes platform, so an agent's tools for Telegram or the terminal don't carry over by
/// themselves; here they can be switched on, or copied from another platform.
struct AgentToolsView: View {
    @ObservedObject var gateway: GatewayClient
    let profileId: String
    let agentName: String
    @State private var tools: AgentToolsData?
    @State private var failure: String?
    @State private var saving = false

    var body: some View {
        List {
            if let failure {
                Text(failure).font(LK.Typography.footnote).foregroundStyle(LK.Palette.danger)
            }
            if let problem = tools?.problem {
                Text(problem).font(LK.Typography.footnote).foregroundStyle(LK.Palette.warning)
            }
            if let elsewhere = tools?.elsewhere, !elsewhere.isEmpty {
                Section {
                    ForEach(elsewhere.keys.sorted(), id: \.self) { platform in
                        Button("Same as \(platform.capitalized)") { copy(from: elsewhere[platform] ?? []) }
                            .disabled(saving)
                    }
                } footer: {
                    Text("Use the tools \(agentName) has on another platform.")
                }
            }
            Section {
                if let toolsets = tools?.toolsets {
                    ForEach(toolsets) { toolset in
                        Toggle(isOn: Binding(get: { toolset.enabled }, set: { on in change([toolset.key: on]) })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(toolset.label)
                                if let description = toolset.description, !description.isEmpty {
                                    Text(description).font(LK.Typography.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(saving)
                    }
                } else if failure == nil {
                    ProgressView().frame(maxWidth: .infinity)
                }
            } footer: {
                Text("Changes are made with Hermes' own tools command, only for Lekora chats, after a backup of \(agentName)'s settings. They apply from the next message.")
            }
        }
        .navigationTitle("Tools")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .overlay { if saving { ProgressView().controlSize(.large) } }
        .task { await load() }
    }

    private func load() async {
        do { tools = try await gateway.agentTools(for: profileId) }
        catch { failure = "Couldn't read \(agentName)'s tools: \(error.localizedDescription)" }
    }

    private func change(_ changes: [String: Bool]) {
        failure = nil
        saving = true
        Task {
            defer { saving = false }
            do { tools = try await gateway.setAgentTools(changes, for: profileId) }
            catch { failure = "Couldn't change that: \(error.localizedDescription)" }
        }
    }

    private func copy(from keys: [String]) {
        guard let toolsets = tools?.toolsets else { return }
        let wanted = Set(keys)
        var changes: [String: Bool] = [:]
        for toolset in toolsets where toolset.enabled != wanted.contains(toolset.key) {
            changes[toolset.key] = wanted.contains(toolset.key)
        }
        if !changes.isEmpty { change(changes) }
    }
}

/// How a personality voice turns a reply into a voice script (docs/voice.md §2).
struct PersonalityInstructionsView: View {
    let agentName: String
    let defaultText: String
    let save: (String?) -> Void
    @State private var draft: String
    @Environment(\.dismiss) private var dismiss

    init(agentName: String, text: String?, defaultText: String, save: @escaping (String?) -> Void) {
        self.agentName = agentName
        self.defaultText = defaultText
        self.save = save
        _draft = State(initialValue: text ?? defaultText)
    }

    var body: some View {
        Form {
            Section {
                TextEditor(text: $draft)
                    .frame(minHeight: 220)
                    .font(LK.Typography.body)
            } footer: {
                Text("Before \(agentName)'s Hermes voice speaks a reply, it's rewritten as a voice script with these instructions: how \(agentName) sounds, and which delivery tags your voice understands (for example [laughs] or (whispers)). The reply you read stays as written. Uses \(agentName)'s model through Hermes, like Hermes' own audio-tag option.")
            }
            Section {
                Button("Use the Default") { draft = defaultText }
            }
        }
        .navigationTitle("Personality Voice")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    save(trimmed.isEmpty || trimmed == defaultText ? nil : trimmed)
                    dismiss()
                }
            }
        }
    }
}
