import SwiftUI

// Skills (docs/skills.md): an agent's Hermes skills: on/off, read and edit, the catalog (with Hermes'
// safety scan before installing), new skills (describe it or write it), remove (always confirmed).

struct SkillsView: View {
    @ObservedObject var gateway: GatewayClient
    let profileId: String
    let agentName: String

    @State private var skills: [SkillInfo] = []
    @State private var loaded = false
    @State private var failure: String?
    @State private var filter = ""
    @State private var addingFromCatalog = false
    @State private var creating = false
    @State private var busy: Set<String> = []

    private var shown: [SkillInfo] {
        let words = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !words.isEmpty else { return skills }
        return skills.filter { $0.name.lowercased().contains(words) || $0.description.lowercased().contains(words)
            || ($0.category ?? "").lowercased().contains(words) }
    }

    var body: some View {
        List {
            if let failure {
                Section { Text(failure).foregroundStyle(LK.Palette.danger) }
            }
            if !loaded && failure == nil {
                Section { HStack { ProgressView(); Text("Asking Hermes…").foregroundStyle(.secondary) } }
            }
            ForEach(LKSkillText.order, id: \.self) { source in
                let group = shown.filter { $0.source == source }.sorted { $0.name < $1.name }
                if !group.isEmpty {
                    Section {
                        ForEach(group) { skill in row(skill) }
                    } header: {
                        Text("\(LKSkillText.source(source)) (\(group.count))")
                    } footer: {
                        if group.contains(where: { $0.essential == true }) {
                            Text("hermes-agent stays on: Hermes needs it to know how it works.")
                        }
                    }
                }
            }
        }
        .searchable(text: $filter, prompt: "Filter \(agentName)'s skills")
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
            SkillCatalogView(gateway: gateway, profileId: profileId, agentName: agentName)
        }
        .sheet(isPresented: $creating, onDismiss: { Task { await load() } }) {
            SkillEditorView(gateway: gateway, profileId: profileId, agentName: agentName, existing: nil)
        }
    }

    private func row(_ skill: SkillInfo) -> some View {
        HStack(spacing: LK.Spacing.md) {
            NavigationLink {
                SkillDetailView(gateway: gateway, profileId: profileId, agentName: agentName, name: skill.name) {
                    Task { await load() }
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(skill.name).font(LK.Typography.body).foregroundStyle(skill.enabled ? .primary : .secondary)
                    if !skill.description.isEmpty {
                        Text(skill.description).font(LK.Typography.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            if busy.contains(skill.name) {
                ProgressView()
            } else {
                Toggle("On", isOn: Binding(get: { skill.enabled }, set: { toggle(skill, $0) }))
                    .labelsHidden()
                    .disabled(skill.essential == true)
                    .accessibilityLabel("\(skill.name) on")
            }
        }
    }

    private func load() async {
        do {
            skills = try await gateway.skills(for: profileId)
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
        loaded = true
    }

    private func toggle(_ skill: SkillInfo, _ on: Bool) {
        busy.insert(skill.name)
        Task {
            defer { busy.remove(skill.name) }
            do {
                let changed = try await gateway.setSkill(skill.name, enabled: on, for: profileId)
                if let index = skills.firstIndex(where: { $0.name == changed.name }) { skills[index] = changed }
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

/// One skill: what it says, where it came from, edit and remove.
struct SkillDetailView: View {
    @ObservedObject var gateway: GatewayClient
    let profileId: String
    let agentName: String
    let name: String
    var changed: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var detail: SkillDetail?
    @State private var failure: String?
    @State private var editing = false
    @State private var confirmingRemove = false
    @State private var removing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LK.Spacing.md) {
                if let detail {
                    HStack(spacing: LK.Spacing.sm) {
                        Text(LKSkillText.source(detail.skill.source))
                        if let trust = detail.skill.trust { Text("· \(LKSkillText.trust(trust))") }
                        if let category = detail.skill.category { Text("· \(category)") }
                        if !detail.skill.enabled { Text("· Off") }
                    }
                    .font(LK.Typography.caption)
                    .foregroundStyle(.secondary)
                    Text(detail.content)
                        .font(LK.Typography.code)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if let failure {
                    Text(failure).foregroundStyle(LK.Palette.danger)
                } else {
                    ProgressView()
                }
            }
            .padding(LK.Spacing.lg)
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if detail?.skill.source != "hub" {
                        Button("Edit", systemImage: "pencil") { editing = true }
                    }
                    if detail?.skill.essential != true {
                        Button("Remove", systemImage: "trash", role: .destructive) { confirmingRemove = true }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .disabled(detail == nil || removing)
            }
        }
        .confirmationDialog("Remove \(name)?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove Skill", role: .destructive) { remove() }
        } message: {
            Text(removeMessage)
        }
        .sheet(isPresented: $editing, onDismiss: { Task { await load(); changed() } }) {
            if let detail {
                SkillEditorView(gateway: gateway, profileId: profileId, agentName: agentName, existing: detail)
            }
        }
        .overlay { if removing { LKBlockingProgress("Removing \(name)…") } }
        .task { await load() }
    }

    private var removeMessage: String {
        switch detail?.skill.source {
        case "hub": return "Hermes uninstalls it from \(agentName). You can install it again from the catalog."
        case "builtin": return "It's moved to a backup on the Hermes instance and Hermes won't add it back. Turning it off is usually better."
        default: return "It's moved to a backup on the Hermes instance, so it isn't lost."
        }
    }

    private func load() async {
        do {
            detail = try await gateway.skill(name, for: profileId)
        } catch {
            failure = error.localizedDescription
        }
    }

    private func remove() {
        removing = true
        Task {
            defer { removing = false }
            do {
                try await gateway.removeSkill(name, for: profileId)
                changed()
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

/// The skills catalog: search, then Hermes' safety scan, then install (confirmed).
struct SkillCatalogView: View {
    @ObservedObject var gateway: GatewayClient
    let profileId: String
    let agentName: String

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
                SkillInstallView(gateway: gateway, profileId: profileId, agentName: agentName, item: item) { dismiss() }
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

/// A catalog skill before installing: who made it and Hermes' scan; Install when Hermes allows it.
struct SkillInstallView: View {
    @ObservedObject var gateway: GatewayClient
    let profileId: String
    let agentName: String
    let item: CatalogSkill
    var installed: () -> Void

    @State private var scan: SkillScan?
    @State private var failure: String?
    @State private var confirming = false
    @State private var installing = false

    var body: some View {
        List {
            Section {
                LabeledContent("From", value: item.source)
                LabeledContent("Made by") { LKTrustBadge(trust: item.trust_level) }
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
                } else if let failure {
                    Text(failure).foregroundStyle(LK.Palette.danger)
                } else {
                    HStack { ProgressView(); Text("Hermes is checking it…").foregroundStyle(.secondary) }
                }
            } header: {
                Text("Hermes' Safety Scan")
            }
            Section {
                Button {
                    confirming = true
                } label: {
                    if installing { ProgressView() } else { Text("Install for \(agentName)") }
                }
                .disabled(scan == nil || scan?.policy == "block" || installing)
            }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Install \(item.name) for \(agentName)?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Install") { install() }
        } message: {
            Text("\(LKSkillText.trust(item.trust_level)) skill from \(item.source). \(agentName) can use it from the next message.")
        }
        .task { await check() }
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
        Task {
            defer { installing = false }
            do {
                try await gateway.installSkill(item.identifier, for: profileId)
                installed()
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

/// New Skill (describe it, or write it) and Edit: the SKILL.md in an editor.
struct SkillEditorView: View {
    @ObservedObject var gateway: GatewayClient
    let profileId: String
    let agentName: String
    /// nil: a new skill.
    let existing: SkillDetail?

    @Environment(\.dismiss) private var dismiss
    @State private var description = ""
    @State private var content = ""
    @State private var category: String?
    @State private var writing = false
    @State private var drafting = false
    @State private var saving = false
    @State private var failure: String?

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
                            Button("Save") { save() }.disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
            }
            .onAppear {
                if let existing, content.isEmpty { content = existing.content }
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
                Text("Hermes' model drafts the skill for \(agentName); you can change it before saving.")
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
        VStack(alignment: .leading, spacing: LK.Spacing.sm) {
            if let failure {
                Text(failure).foregroundStyle(LK.Palette.danger).padding(.horizontal)
            }
            Text("The header's name (lowercase, -) and description (up to 60 characters) are what \(agentName) sees first.")
                .font(LK.Typography.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            TextEditor(text: $content)
                .font(LK.Typography.code)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(.horizontal, LK.Spacing.sm)
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
        Task {
            defer { saving = false }
            do {
                try await gateway.saveSkill(content: content, name: existing?.skill.name, category: category,
                                            create: existing == nil, for: profileId)
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
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
