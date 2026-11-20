import SwiftUI

// Group chats (docs/group-chats.md): making and changing a group, and @mentions while writing.

/// New Group, or a group's settings: its name, which agents are in it, and Delete.
struct GroupEditorView: View {
    @ObservedObject var gateway: GatewayClient
    /// nil: a new group.
    let group: GroupData?
    /// A new group was made (to open it).
    var created: (GroupData) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var members: [String] = []
    @State private var saving = false
    @State private var failure: String?
    @State private var confirmingDelete = false
    @State private var details: GroupDetails?
    @State private var loadingDetails = false

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && members.count >= 2 && !saving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Group Name", text: $name)
                        .textInputAutocapitalization(.words)
                }
                Section {
                    ForEach(gateway.profiles) { profile in
                        Button {
                            toggle(profile.profile_id)
                        } label: {
                            HStack(spacing: LK.Spacing.md) {
                                LKAgentAvatar(id: profile.profile_id, palette: gateway.avatarPalettes[profile.profile_id], size: 32)
                                Text(profile.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: members.contains(profile.profile_id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(members.contains(profile.profile_id) ? AnyShapeStyle(LK.Palette.accent) : AnyShapeStyle(.tertiary))
                                    .font(.title3)
                            }
                        }
                        .tint(.primary)
                        .accessibilityAddTraits(members.contains(profile.profile_id) ? .isSelected : [])
                    }
                } header: {
                    Text("Agents")
                } footer: {
                    Text("Pick two or more. In the group, @name talks to one agent; without an @mention, everyone answers.")
                }
                if let failure {
                    Section {
                        Text(failure).foregroundStyle(LK.Palette.danger)
                    }
                }
                if group != nil {
                    detailsSection
                }
                if let group {
                    Section {
                        Button("Delete Group", role: .destructive) { confirmingDelete = true }
                    } footer: {
                        Text("Deletes \(group.name) and its messages, on every phone. The agents themselves stay.")
                    }
                }
            }
            .navigationTitle(group == nil ? "New Group" : "Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button(group == nil ? "Create" : "Save") { save() }
                            .disabled(!canSave)
                    }
                }
            }
            .confirmationDialog("Delete \(group?.name ?? "this group")?", isPresented: $confirmingDelete,
                                titleVisibility: .visible) {
                Button("Delete Group", role: .destructive) { delete() }
            } message: {
                Text("Its messages are deleted on every phone. The agents stay.")
            }
            .onAppear {
                name = group?.name ?? ""
                members = group?.members ?? []
            }
        }
    }

    // MARK: - Details (owner, 2026-11-20): each agent's side of the group, from Hermes

    @ViewBuilder
    private var detailsSection: some View {
        Section {
            if let details {
                LabeledContent("Cost", value: LKUsageText.cost(details.totals.cost_usd) ?? "—")
                LabeledContent("Tokens", value: LKUsageText.tokens(in: details.totals.input_tokens,
                                                                   out: details.totals.output_tokens) ?? "—")
                ForEach(details.members) { member in
                    memberRow(member)
                }
            } else if loadingDetails {
                HStack { ProgressView(); Text("Asking Hermes…").foregroundStyle(.secondary) }
            } else {
                Text("Details are shown once the group is connected.").foregroundStyle(.secondary)
            }
        } header: {
            Text("Details")
        } footer: {
            Text("Each agent has its own side of the group in Hermes, with its own context and cost. Totals add them up.")
        }
        .task(id: group?.group_id) { await loadDetails() }
    }

    private func memberRow(_ member: GroupDetails.Member) -> some View {
        HStack(alignment: .top, spacing: LK.Spacing.md) {
            LKAgentAvatar(id: member.profile_id, palette: gateway.avatarPalettes[member.profile_id], size: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(gateway.agentName(member.profile_id)).font(LK.Typography.headline)
                    Spacer()
                    Text(LKUsageText.cost(member.usage?.cost_usd) ?? "—")
                        .font(LK.Typography.subheadline.monospacedDigit())
                }
                if let title = member.title, !title.isEmpty {
                    Text("“\(title)”").font(LK.Typography.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                Text([member.model?.components(separatedBy: "/").last,
                      LKUsageText.context(member.usage),
                      LKUsageText.tokens(in: member.usage?.input_tokens, out: member.usage?.output_tokens)]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(LK.Typography.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func loadDetails() async {
        guard let group else { return }
        loadingDetails = true
        defer { loadingDetails = false }
        details = try? await gateway.groupDetails(group.group_id)
    }

    private func toggle(_ id: String) {
        if let index = members.firstIndex(of: id) {
            members.remove(at: index)
        } else {
            members.append(id)
        }
    }

    private func save() {
        saving = true
        failure = nil
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        // Kept in the host's agent order.
        let ordered = gateway.profiles.map(\.profile_id).filter { members.contains($0) }
        Task {
            defer { saving = false }
            do {
                if let group {
                    try await gateway.updateGroup(group.group_id, name: trimmed, members: ordered)
                    dismiss()
                } else {
                    let made = try await gateway.createGroup(name: trimmed, members: ordered)
                    dismiss()
                    created(made)
                }
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    private func delete() {
        guard let group else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                try await gateway.deleteGroup(group.group_id)
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

/// While writing "@co…" in a group: the members it could be, to tap.
enum LKMentionMatcher {
    /// The "@word" being written at the end of the text, without the "@" (nil when none).
    static func partial(in text: String) -> String? {
        guard let at = text.lastIndex(of: "@") else { return nil }
        if at > text.startIndex, !text[text.index(before: at)].isWhitespace { return nil }  // an e-mail address
        let word = text[text.index(after: at)...]
        guard !word.contains(where: \.isWhitespace) else { return nil }
        return String(word)
    }

    /// "all" (Everyone), then members whose id or name starts with what's written.
    static func suggestions(for text: String, members: [ProfileData]) -> [(handle: String, name: String)] {
        guard let partial = partial(in: text)?.lowercased() else { return [] }
        // "Everyone" first: it's the one that would otherwise sit off the edge.
        var out: [(handle: String, name: String)] = "all".hasPrefix(partial) ? [(handle: "all", name: "Everyone")] : []
        out += members
            .filter { $0.profile_id.lowercased().hasPrefix(partial) || $0.name.lowercased().hasPrefix(partial) }
            .map { (handle: $0.profile_id, name: $0.name) }
        return out
    }

    /// The agents a message @mentions (by id, or name without spaces), in the order written.
    static func mentioned(in text: String, among profiles: [ProfileData]) -> [String] {
        var handles: [String: String] = [:]
        for profile in profiles {
            handles[profile.profile_id.lowercased()] = profile.profile_id
            handles[profile.name.filter { !$0.isWhitespace }.lowercased()] = profile.profile_id
        }
        var found: [String] = []
        let words = text.split(whereSeparator: { $0.isWhitespace })
        for word in words where word.hasPrefix("@") {
            let handle = word.dropFirst().lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            if let id = handles[handle], !found.contains(id) { found.append(id) }
        }
        return found
    }

    /// The text with the "@word" being written completed to "@handle ".
    static func complete(_ text: String, with handle: String) -> String {
        guard let at = text.lastIndex(of: "@") else { return text }
        return String(text[..<at]) + "@" + handle + " "
    }
}

struct LKMentionSuggestions: View {
    let suggestions: [(handle: String, name: String)]
    let pick: (String) -> Void
    var palettes: [String: Int] = [:]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: LK.Spacing.sm) {
                ForEach(suggestions, id: \.handle) { item in
                    Button { pick(item.handle) } label: {
                        HStack(spacing: LK.Spacing.xs) {
                            if item.handle == "all" {
                                Image(systemName: "person.3.fill").font(LK.Typography.caption)
                            } else {
                                LKAgentAvatar(id: item.handle, palette: palettes[item.handle], size: 22)
                            }
                            Text(item.name).font(LK.Typography.subheadline)
                        }
                        .padding(.horizontal, LK.Spacing.md)
                        .padding(.vertical, LK.Spacing.xs)
                    }
                    .buttonStyle(.glass)
                    .accessibilityLabel("Mention \(item.name)")
                }
            }
            .padding(.horizontal, LK.Spacing.lg)
        }
    }
}

/// Usage in words: "$0.15", "12k in · 2k out", "3% of 200k context".
enum LKUsageText {
    static func cost(_ usd: Double?) -> String? {
        guard let usd else { return nil }
        return usd < 0.01 ? (usd == 0 ? "$0" : "<$0.01") : String(format: "$%.2f", usd)
    }

    static func tokens(in input: Int?, out output: Int?) -> String? {
        guard input != nil || output != nil else { return nil }
        return "\(short(input ?? 0)) in · \(short(output ?? 0)) out"
    }

    static func context(_ usage: ChatSettingsData.Usage?) -> String? {
        guard let used = usage?.context_tokens, let total = usage?.context_length, total > 0 else { return nil }
        return "\(Int((Double(used) / Double(total) * 100).rounded()))% of \(short(total)) context"
    }

    static func short(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1_000_000)
            : n >= 1000 ? "\(Int((Double(n) / 1000).rounded()))k" : "\(n)"
    }
}
