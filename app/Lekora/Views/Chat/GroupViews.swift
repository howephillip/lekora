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
