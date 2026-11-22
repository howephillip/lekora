import SwiftUI

// Skills (docs/skills.md): one page for every agent's Hermes skills (owner, 2026-11-22). Hermes keeps
// skills per agent; this shows each skill once with the agents that have it.

struct SkillsView: View {
    @ObservedObject var gateway: GatewayClient

    @State private var skills: [SharedSkill] = []
    @State private var loaded = false
    @State private var failure: String?
    @State private var filter = ""
    @State private var addingFromCatalog = false
    @State private var creating = false

    private var shown: [SharedSkill] {
        let words = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !words.isEmpty else { return skills }
        return skills.filter { $0.name.lowercased().contains(words) || $0.description.lowercased().contains(words)
            || ($0.category ?? "").lowercased().contains(words)
            || $0.agents.contains { gateway.agentName($0.profile_id).lowercased().contains(words) } }
    }

    private var categories: [String] {
        // "Other" (no category) goes last.
        Array(Set(shown.map { $0.category ?? "other" })).sorted { ($0 == "other" ? 1 : 0, $0) < ($1 == "other" ? 1 : 0, $1) }
    }

    var body: some View {
        List {
            if let failure {
                Section { Text(failure).foregroundStyle(LK.Palette.danger) }
            }
            if !loaded && failure == nil {
                Section { HStack { ProgressView(); Text("Asking Hermes…").foregroundStyle(.secondary) } }
            }
            ForEach(categories, id: \.self) { category in
                Section(category.prefix(1).uppercased() + category.dropFirst()) {
                    ForEach(shown.filter { ($0.category ?? "other") == category }) { skill in
                        NavigationLink {
                            SkillDetailView(gateway: gateway, name: skill.name) { Task { await load() } }
                        } label: {
                            row(skill)
                        }
                    }
                }
            }
        }
        .searchable(text: $filter, prompt: "Filter skills or agents")
        .navigationTitle("Skills")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Find in Catalog", systemImage: "magnifyingglass") { addingFromCatalog = true }
                    Button("New Skill", systemImage: "square.and.pencil") { creating = true }
                } label: {
                    Label("Add Skill", systemImage: "plus")
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $addingFromCatalog, onDismiss: { Task { await load() } }) {
            SkillCatalogView(gateway: gateway)
        }
        .sheet(isPresented: $creating, onDismiss: { Task { await load() } }) {
            SkillEditorView(gateway: gateway, existing: nil)
        }
    }

    private func row(_ skill: SharedSkill) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(skill.name)
            if !skill.description.isEmpty {
                Text(skill.description).font(LK.Typography.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            LKSkillAgents(gateway: gateway, agents: skill.agents)
        }
    }

    private func load() async {
        do {
            skills = try await gateway.allSkills()
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
        loaded = true
    }
}

/// The agents that have a skill: their bots, faded where it's off.
struct LKSkillAgents: View {
    @ObservedObject var gateway: GatewayClient
    let agents: [SharedSkill.Agent]

    var body: some View {
        let count = gateway.profiles.count
        HStack(spacing: 4) {
            ForEach(agents.prefix(8), id: \.profile_id) { agent in
                LKAgentAvatar(id: agent.profile_id, palette: gateway.avatarPalettes[agent.profile_id], size: 18)
                    .opacity(agent.enabled ? 1 : 0.35)
            }
            Text(agents.count == count && count > 1 ? "All agents" : agents.map { gateway.agentName($0.profile_id) }.joined(separator: ", "))
                .font(LK.Typography.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Agents: " + agents.map { gateway.agentName($0.profile_id) + ($0.enabled ? "" : " (off)") }.joined(separator: ", "))
    }
}

/// One skill: its instructions, and every agent: on/off, add to, remove from; edit.
struct SkillDetailView: View {
    @ObservedObject var gateway: GatewayClient
    let name: String
    var changed: () -> Void = {}

    @State private var shared: SharedSkill?
    @State private var detail: SkillDetail?
    @State private var failure: String?
    @State private var editing = false
    @State private var busy: Set<String> = []
    @State private var removing: String?

    var body: some View {
        List {
            if let failure {
                Section { Text(failure).foregroundStyle(LK.Palette.danger) }
            }
            if let shared {
                Section {
                    ForEach(gateway.profiles) { profile in
                        agentRow(profile, shared.agents.first { $0.profile_id == profile.profile_id })
                    }
                } header: {
                    Text("Agents")
                } footer: {
                    Text("Off means that agent doesn't use it anywhere. Hermes' own hermes-agent skill always stays on.")
                }
            }
            Section("Instructions") {
                if let detail {
                    Text(detail.content)
                        .font(LK.Typography.code)
                        .textSelection(.enabled)
                } else if failure == nil {
                    ProgressView()
                }
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let detail, detail.skill.source != "hub", detail.skill.source != "lekora" {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { editing = true }
                }
            }
        }
        .confirmationDialog("Remove \(name) from \(removing.map(gateway.agentName) ?? "")?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) { if let removing { remove(from: removing) } }
        } message: {
            Text(removeMessage)
        }
        .sheet(isPresented: $editing, onDismiss: { Task { await load(); changed() } }) {
            if let detail { SkillEditorView(gateway: gateway, existing: detail, owners: editableOwners) }
        }
        .task { await load() }
    }

    /// Agents whose own copy an edit changes (not catalog copies, which Hermes keeps up to date).
    private var editableOwners: [String] {
        (shared?.agents ?? []).filter { $0.source != "hub" && $0.source != "lekora" }.map(\.profile_id)
    }

    private var removeMessage: String {
        guard let removing, let agent = shared?.agents.first(where: { $0.profile_id == removing }) else { return "" }
        switch agent.source {
        case "hub": return "Hermes uninstalls it from \(gateway.agentName(removing))."
        case "builtin": return "It's moved to a backup on the Hermes instance and Hermes won't add it back. Turning it off is usually better."
        default: return "It's moved to a backup on the Hermes instance, so it isn't lost."
        }
    }

    @ViewBuilder
    private func agentRow(_ profile: ProfileData, _ agent: SharedSkill.Agent?) -> some View {
        let id = profile.profile_id
        HStack(spacing: LK.Spacing.md) {
            LKAgentAvatar(id: id, palette: gateway.avatarPalettes[id], size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                Text(agent.map { LKSkillText.source($0.source) } ?? "Doesn't have it")
                    .font(LK.Typography.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if busy.contains(id) {
                ProgressView()
            } else if let agent {
                Toggle(profile.name, isOn: Binding(get: { agent.enabled }, set: { toggle(id, $0) }))
                    .labelsHidden()
                    .disabled(agent.essential == true)
            } else {
                Button("Add") { add(to: id) }
                    .buttonStyle(.bordered)
                    .disabled(shared?.agents.isEmpty != false)
            }
        }
        .swipeActions {
            if let agent, agent.essential != true, agent.source != "lekora" {
                Button("Remove", role: .destructive) { removing = id }
            }
        }
    }

    private func load() async {
        do {
            shared = try await gateway.allSkills().first { $0.name == name }
            if let owner = shared?.agents.first?.profile_id {
                detail = try await gateway.skill(name, for: owner)
            }
            failure = shared == nil ? "No agent has this skill any more." : nil
        } catch {
            failure = error.localizedDescription
        }
    }

    private func run(_ id: String, _ work: @escaping () async throws -> Void) {
        busy.insert(id)
        Task {
            defer { busy.remove(id) }
            do {
                try await work()
                await load()
                changed()
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    private func toggle(_ id: String, _ on: Bool) {
        run(id) { try await gateway.setSkill(name, enabled: on, for: id) }
    }

    private func add(to id: String) {
        guard let owner = shared?.agents.first(where: { $0.source == "hub" })?.profile_id ?? shared?.agents.first?.profile_id else { return }
        run(id) {
            let result = try await gateway.copySkill(name, from: owner, to: [id])
            if let failed = result.failed.first { throw SkillsFailure(reason: failed.reason) }
        }
    }

    private func remove(from id: String) {
        run(id) { try await gateway.removeSkill(name, for: id) }
    }
}

struct SkillsFailure: LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
}

/// Which agents get a skill (all, by default).
struct LKAgentPicker: View {
    @ObservedObject var gateway: GatewayClient
    @Binding var chosen: Set<String>

    var body: some View {
        ForEach(gateway.profiles) { profile in
            Button {
                if chosen.contains(profile.profile_id) { chosen.remove(profile.profile_id) } else { chosen.insert(profile.profile_id) }
            } label: {
                HStack(spacing: LK.Spacing.md) {
                    LKAgentAvatar(id: profile.profile_id, palette: gateway.avatarPalettes[profile.profile_id], size: 26)
                    Text(profile.name).foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: chosen.contains(profile.profile_id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(chosen.contains(profile.profile_id) ? AnyShapeStyle(LK.Palette.accent) : AnyShapeStyle(.tertiary))
                }
            }
            .tint(.primary)
            .accessibilityAddTraits(chosen.contains(profile.profile_id) ? .isSelected : [])
        }
    }
}

/// The skills catalog: search, then Hermes' safety scan, then install for the chosen agents.
struct SkillCatalogView: View {
    @ObservedObject var gateway: GatewayClient

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [CatalogSkill] = []
    @State private var searching = false
    @State private var failure: String?
    @State private var picked: CatalogSkill?

    var body: some View {
        NavigationStack {
            List {
                if let failure {
                    Section { Text(failure).foregroundStyle(LK.Palette.danger) }
                }
                if searching {
                    Section { HStack { ProgressView(); Text("Searching the catalog…").foregroundStyle(.secondary) } }
                } else if results.isEmpty {
                    Section {
                        Text(query.isEmpty ? "Search Hermes' skills catalog: official skills, and skills from Anthropic, OpenAI and community sources."
                             : "Nothing found for “\(query)”.")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(results) { item in
                    Button { picked = item } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(item.name).foregroundStyle(.primary)
                                Spacer()
                                LKTrustBadge(trust: item.trust_level)
                            }
                            Text(item.description).font(LK.Typography.caption).foregroundStyle(.secondary).lineLimit(2)
                            Text(item.source).font(Font.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .tint(.primary)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search skills")
            .onSubmit(of: .search) { search() }
            .navigationTitle("Skills Catalog")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .navigationDestination(item: $picked) { item in
                SkillInstallView(gateway: gateway, item: item) { dismiss() }
            }
        }
    }

    private func search() {
        let words = query.trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty else { return }
        searching = true
        failure = nil
        Task {
            defer { searching = false }
            do {
                results = try await gateway.searchSkills(words)
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

/// A catalog skill before installing: who made it, Hermes' scan, and which agents get it.
struct SkillInstallView: View {
    @ObservedObject var gateway: GatewayClient
    let item: CatalogSkill
    var installed: () -> Void

    @State private var scan: SkillScan?
    @State private var failure: String?
    @State private var confirming = false
    @State private var installing = false
    @State private var chosen: Set<String> = []

    var body: some View {
        List {
            Section {
                LabeledContent("From", value: item.source)
                LabeledContent("Trust") { LKTrustBadge(trust: item.trust_level) }
                Text(item.description).foregroundStyle(.secondary)
            }
            Section {
                if let scan {
                    HStack {
                        Text("Verdict")
                        Spacer()
                        Label(LKSkillText.verdict(scan.verdict), systemImage: LKSkillText.verdictSymbol(scan.verdict))
                            .foregroundStyle(scan.verdict == "safe" ? LK.Palette.success : scan.verdict == "dangerous" ? LK.Palette.danger : LK.Palette.warning)
                    }
                    if let summary = scan.summary, !summary.isEmpty { Text(summary).font(LK.Typography.footnote) }
                    ForEach(scan.findings, id: \.self) { finding in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(finding.severity.capitalized): \(finding.description)").font(LK.Typography.footnote)
                            if let file = finding.file {
                                Text(finding.line.map { "\(file):\($0)" } ?? file).font(LK.Typography.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if scan.policy == "block" {
                        Text("Hermes won't install this: \(scan.policy_reason ?? "its safety check blocked it").")
                            .foregroundStyle(LK.Palette.danger)
                    }
                } else if failure == nil {
                    HStack { ProgressView(); Text("Hermes is checking it…").foregroundStyle(.secondary) }
                }
            } header: {
                Text("Hermes' Safety Scan")
            }
            Section("Install For") {
                LKAgentPicker(gateway: gateway, chosen: $chosen)
            }
            if let failure {
                Section { Text(failure).foregroundStyle(LK.Palette.danger) }
            }
            Section {
                Button {
                    confirming = true
                } label: {
                    if installing { ProgressView() } else { Text(chosen.count == 1 ? "Install for 1 Agent" : "Install for \(chosen.count) Agents") }
                }
                .disabled(scan == nil || scan?.policy == "block" || installing || chosen.isEmpty)
            }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Install \(item.name)?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Install") { install() }
        } message: {
            Text("\(LKSkillText.trust(item.trust_level)) skill from \(item.source), for \(chosenNames). They can use it from their next message.")
        }
        .onAppear { if chosen.isEmpty { chosen = Set(gateway.profiles.map(\.profile_id)) } }
        .task { await check() }
    }

    private var chosenNames: String {
        gateway.profiles.filter { chosen.contains($0.profile_id) }.map(\.name).joined(separator: ", ")
    }

    private func check() async {
        do {
            scan = try await gateway.scanSkill(item.identifier)
        } catch {
            failure = error.localizedDescription
        }
    }

    private func install() {
        installing = true
        failure = nil
        let targets = gateway.profiles.map(\.profile_id).filter { chosen.contains($0) }
        Task {
            defer { installing = false }
            var problems: [String] = []
            for target in targets {
                do {
                    try await gateway.installSkill(item.identifier, for: target)
                } catch {
                    problems.append("\(gateway.agentName(target)): \(error.localizedDescription)")
                }
            }
            if problems.isEmpty { installed() } else { failure = problems.joined(separator: "\n") }
        }
    }
}

/// New Skill (describe it, or write it) for the chosen agents, and Edit (every agent's own copy).
struct SkillEditorView: View {
    @ObservedObject var gateway: GatewayClient
    /// nil: a new skill.
    let existing: SkillDetail?
    /// Edit: the agents whose copy changes.
    var owners: [String] = []

    @Environment(\.dismiss) private var dismiss
    @State private var description = ""
    @State private var content = ""
    @State private var category: String?
    @State private var writing = false
    @State private var drafting = false
    @State private var saving = false
    @State private var failure: String?
    @State private var chosen: Set<String> = []

    private static let blank = "---\nname: my-skill\ndescription: \"What it does, in 60 characters\"\nversion: 1.0.0\n---\n\n## When to use\n\n## Steps\n\n1. \n"

    var body: some View {
        NavigationStack {
            Group {
                if existing == nil && !writing {
                    describeForm
                } else {
                    editor
                }
            }
            .navigationTitle(existing.map { "Edit \($0.skill.name)" } ?? "New Skill")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                if existing != nil || writing {
                    ToolbarItem(placement: .confirmationAction) {
                        if saving { ProgressView() } else {
                            Button("Save") { save() }
                                .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                          || (existing == nil && chosen.isEmpty))
                        }
                    }
                }
            }
            .onAppear {
                if let existing, content.isEmpty { content = existing.content }
                if chosen.isEmpty { chosen = Set(gateway.profiles.map(\.profile_id)) }
            }
        }
    }

    private var describeForm: some View {
        Form {
            Section {
                TextField("For example: every Friday, sum up my week from my calendar and email", text: $description, axis: .vertical)
                    .lineLimit(3...8)
            } header: {
                Text("Describe It")
            } footer: {
                Text("Hermes' model drafts the skill; you can change it before saving.")
            }
            if let failure {
                Section { Text(failure).foregroundStyle(LK.Palette.danger) }
            }
            Section {
                Button {
                    draft()
                } label: {
                    if drafting { HStack { ProgressView(); Text("Drafting…") } } else { Text("Draft Skill") }
                }
                .disabled(description.trimmingCharacters(in: .whitespaces).isEmpty || drafting)
                Button("Write It Myself") {
                    content = Self.blank
                    writing = true
                }
            }
        }
    }

    private var editor: some View {
        Form {
            if let failure {
                Section { Text(failure).foregroundStyle(LK.Palette.danger) }
            }
            Section {
                TextEditor(text: $content)
                    .font(LK.Typography.code)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .frame(minHeight: 320)
            } footer: {
                Text("The header's name (lowercase, -) and description (up to 60 characters) are what agents see first.")
            }
            if existing == nil {
                Section("Give It To") {
                    LKAgentPicker(gateway: gateway, chosen: $chosen)
                }
            } else if owners.count > 1 {
                Section {
                    Text("Saved for " + owners.map(gateway.agentName).joined(separator: ", ") + ".")
                        .font(LK.Typography.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func draft() {
        drafting = true
        failure = nil
        Task {
            defer { drafting = false }
            do {
                let got = try await gateway.draftSkill(description)
                content = got.content
                category = got.category
                writing = true
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    private func save() {
        saving = true
        failure = nil
        let targets = existing == nil ? gateway.profiles.map(\.profile_id).filter { chosen.contains($0) } : owners
        Task {
            defer { saving = false }
            var problems: [String] = []
            for target in targets {
                do {
                    try await gateway.saveSkill(content: content, name: existing?.skill.name, category: category,
                                                create: existing == nil, for: target)
                } catch {
                    problems.append("\(gateway.agentName(target)): \(error.localizedDescription)")
                }
            }
            if problems.isEmpty { dismiss() } else { failure = problems.joined(separator: "\n") }
        }
    }
}

/// Official / trusted / community, as Hermes rates a catalog source.
struct LKTrustBadge: View {
    let trust: String

    var body: some View {
        Text(LKSkillText.trust(trust))
            .font(Font.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background((trust == "community" ? LK.Palette.warning : LK.Palette.accent).opacity(0.15), in: Capsule())
            .foregroundStyle(trust == "community" ? LK.Palette.warning : LK.Palette.accent)
    }
}

enum LKSkillText {
    /// Sections in the list, in this order.
    static let order = ["local", "hub", "builtin", "external"]

    static func source(_ source: String) -> String {
        switch source {
        case "local": return "Made Here"
        case "hub": return "From the Catalog"
        case "builtin": return "Built In"
        case "lekora": return "From Lekora"
        default: return "Shared"
        }
    }

    static func trust(_ level: String) -> String {
        switch level {
        case "builtin": return "Official"
        case "trusted": return "Trusted"
        case "agent-created": return "Agent-made"
        default: return "Community"
        }
    }

    static func verdict(_ verdict: String?) -> String {
        switch verdict {
        case "safe": return "Safe"
        case "caution": return "Caution"
        case "dangerous": return "Dangerous"
        default: return "Unknown"
        }
    }

    static func verdictSymbol(_ verdict: String?) -> String {
        switch verdict {
        case "safe": return "checkmark.shield.fill"
        case "dangerous": return "xmark.shield.fill"
        default: return "exclamationmark.shield.fill"
        }
    }
}
