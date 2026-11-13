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

/// Personality voice (docs/voice.md §2): who's speaking (the agent's own Hermes personality, or
/// the user's own words) and how they talk: filler words, pauses, pace.
struct PersonalityVoiceView: View {
    let agentName: String
    /// Hermes' personalities for this agent (catgirl, helpful, hype…), from its Hermes settings.
    let presets: [String]
    let save: (AgentVoiceSettings) -> Void
    @State private var settings: AgentVoiceSettings
    @State private var custom: String

    init(agentName: String, settings: AgentVoiceSettings, presets: [String], save: @escaping (AgentVoiceSettings) -> Void) {
        self.agentName = agentName
        self.presets = presets
        self.save = save
        _settings = State(initialValue: settings)
        _custom = State(initialValue: settings.style_instructions ?? "")
    }

    var body: some View {
        Form {
            Section {
                choice("\(agentName)'s Own", detail: "As set up in Hermes: its persona and personality", source: "hermes", preset: nil)
                choice("My Own", detail: "Write the personality yourself", source: "custom", preset: nil)
            } header: {
                Text("Who's Speaking")
            }
            if !presets.isEmpty {
                Section {
                    ForEach(presets, id: \.self) { name in
                        choice(name.capitalized, detail: nil, source: "preset", preset: name)
                    }
                } header: {
                    Text("Hermes Personalities")
                } footer: {
                    Text("Only changes how \(agentName) sounds, not how it writes.")
                }
            }
            if settings.style_source == "custom" {
                Section {
                    TextEditor(text: $custom)
                        .frame(minHeight: 160)
                        .overlay(alignment: .topLeading) {
                            if custom.isEmpty {
                                Text("e.g. A laid-back surfer who laughs easily and says \"dude\" a lot.")
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                } header: {
                    Text("Your Personality")
                } footer: {
                    Text("Describe how \(agentName) should sound: character, attitude, accent, catchphrases, and any delivery tags your voice understands (like [laughs] or (whispers)). Saved when you leave this screen.")
                }
            }
            Section {
                level("Filler Words", \.fillers, ["None", "Some", "Lots"])
                level("Pauses", \.pauses, ["Few", "Natural", "Lots"])
                level("Pace", \.pace, ["Calm", "Natural", "Lively"])
            } header: {
                Text("Cadence")
            } footer: {
                Text("Filler words are the \"uh\", \"um\", \"like\" and \"you know\" of real speech; pauses are the beats between thoughts.\n\nWhile Personality Voice is on, \(agentName) is told (through Hermes, for each message) to write its replies the way it talks, like this. Its Hermes voice then says exactly that, so what you hear, what you read and what \(agentName) remembers are the same.")
            }
        }
        .navigationTitle("Voice Personality")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onDisappear(perform: commit)
    }

    private func choice(_ title: String, detail: String?, source: String, preset: String?) -> some View {
        Button {
            settings.style_source = source
            settings.style_preset = preset
            commit()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).foregroundStyle(.primary)
                    if let detail { Text(detail).font(LK.Typography.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if settings.style_source == source && settings.style_preset == preset {
                    Image(systemName: "checkmark").foregroundStyle(LK.Palette.accent).fontWeight(.semibold)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func binding<T>(_ key: WritableKeyPath<AgentVoiceSettings, T>) -> Binding<T> {
        Binding(get: { settings[keyPath: key] }, set: { settings[keyPath: key] = $0; commit() })
    }

    private func level(_ title: String, _ key: WritableKeyPath<AgentVoiceSettings, Int>, _ names: [String]) -> some View {
        VStack(alignment: .leading, spacing: LK.Spacing.xs) {
            Text(title)
            Picker(title, selection: binding(key)) {
                ForEach(names.indices, id: \.self) { Text(names[$0]).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    /// Saved when a choice changes, and the text when leaving.
    private func commit() {
        var updated = settings
        let trimmed = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.style_instructions = trimmed.isEmpty ? nil : trimmed
        guard updated != lastSaved else { return }
        lastSaved = updated
        save(updated)
    }

    @State private var lastSaved: AgentVoiceSettings?
}
