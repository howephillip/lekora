import SwiftUI

/// The agent selector: which Hermes profiles this phone uses, plus adding and deleting
/// agents (docs/agent-lifecycle.md). The last setup step after pairing (skipped when the
/// host has only one agent), and reachable later from the chat's agent menu.
public struct ChooseProfilesView: View {
    public enum Mode {
        /// End of setup: no way back, Continue goes to the chat.
        case setup
        /// Changing the choice later, shown as a sheet with Cancel.
        case edit
    }

    @ObservedObject public var gateway: GatewayClient
    public let mode: Mode
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String>
    @State private var addingAgent = false
    @State private var pendingDelete: ProfileData?
    @State private var deleting: ProfileData?
    @State private var failure: String?

    public init(gateway: GatewayClient, mode: Mode) {
        self.gateway = gateway
        self.mode = mode
        // Setup starts with everything on; editing starts from the current choice.
        let current = gateway.enabledProfiles.map(\.profile_id)
        _selected = State(initialValue: Set(current.isEmpty ? gateway.profiles.map(\.profile_id) : current))
    }

    private var instanceName: String {
        gateway.savedHost?.instanceName ?? "Hermes"
    }

    /// Only agents that still exist on the host count.
    private var chosen: [String] {
        gateway.profiles.map(\.profile_id).filter { selected.contains($0) }
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    header
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

                Section {
                    ForEach(gateway.profiles) { profile in
                        row(profile)
                    }
                    Button {
                        addingAgent = true
                    } label: {
                        Label("Add Agent", systemImage: "plus.circle.fill")
                            .font(LK.Typography.headline)
                            .foregroundStyle(LK.Palette.accent)
                    }
                } footer: {
                    Text("Swipe left on an agent to delete it. The default agent can't be deleted.")
                        .font(LK.Typography.caption)
                }
            }
            .scrollContentBackground(.hidden)
            .lkScreenBackground()
            .safeAreaBar(edge: .bottom) {
                VStack(spacing: LK.Spacing.xs) {
                    LKPrimaryButton(mode == .setup ? "Continue" : "Done") {
                        gateway.chooseProfiles(chosen)
                        if mode == .edit { dismiss() }
                    }
                    .disabled(chosen.isEmpty)
                    Text(chosen.isEmpty ? "Choose at least one agent." : "You can change this later from the agent menu in the chat.")
                        .font(LK.Typography.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, LK.Spacing.lg)
                .padding(.vertical, LK.Spacing.sm)
            }
            .toolbar {
                if mode == .edit {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
            .sheet(isPresented: $addingAgent) {
                AddAgentView(gateway: gateway, instanceName: instanceName) { created in
                    selected.insert(created.profile_id)
                }
            }
            .confirmationDialog(
                "Delete \(pendingDelete?.name ?? "agent")?",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { profile in
                Button("Delete \(profile.name)", role: .destructive) {
                    delete(profile)
                }
            } message: { profile in
                Text("This deletes the \(profile.name) agent on \(instanceName), including its settings, memory and chats. A backup is saved on the Hermes computer first.")
            }
            .alert("Couldn't change agents", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(failure ?? "")
            }
            .overlay {
                if let deleting {
                    LKBlockingProgress("Backing up and deleting \(deleting.name)…")
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: LK.Spacing.sm) {
            Image(systemName: "person.2.wave.2")
                .font(.system(size: LK.Size.heroIcon))
                .foregroundStyle(LK.Palette.accent.gradient)
                .padding(.bottom, LK.Spacing.xs)
            Text(mode == .setup ? "Choose Your Agents" : "Your Agents")
                .font(LK.Typography.largeTitle)
                .multilineTextAlignment(.center)
            Text("Pick which agents on \(instanceName) you want to chat with on this iPhone.")
                .font(LK.Typography.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, mode == .setup ? LK.Spacing.lg : 0)
        .padding(.bottom, LK.Spacing.sm)
    }

    private func row(_ profile: ProfileData) -> some View {
        let isOn = selected.contains(profile.profile_id)
        let canDelete = profile.profile_id != "default"
        return Button {
            if isOn {
                selected.remove(profile.profile_id)
            } else {
                selected.insert(profile.profile_id)
            }
        } label: {
            HStack(spacing: LK.Spacing.md) {
                LKAgentAvatar(profile.name)
                VStack(alignment: .leading, spacing: LK.Spacing.xxs) {
                    Text(profile.name)
                        .font(LK.Typography.headline)
                        .foregroundStyle(.primary)
                    if let description = profile.description, !description.isEmpty {
                        Text(description)
                            .font(LK.Typography.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(isOn ? AnyShapeStyle(LK.Palette.accent) : AnyShapeStyle(.tertiary))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        // Not a destructive role: that would remove the row before the user confirms.
        .swipeActions(edge: .trailing) {
            if canDelete {
                Button {
                    pendingDelete = profile
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .tint(LK.Palette.danger)
            }
        }
        .contextMenu {
            if canDelete {
                Button("Delete Agent…", systemImage: "trash", role: .destructive) {
                    pendingDelete = profile
                }
            }
        }
    }

    private func delete(_ profile: ProfileData) {
        deleting = profile
        Task {
            defer { deleting = nil }
            do {
                try await gateway.deleteProfile(profile.profile_id)
                selected.remove(profile.profile_id)
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

/// "Add Agent": name (required) and what it's for (optional). The host clones the
/// default agent's settings, so the new agent works straight away.
struct AddAgentView: View {
    @ObservedObject var gateway: GatewayClient
    let instanceName: String
    let onCreated: (ProfileData) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var purpose = ""
    @State private var creating = false
    @State private var failure: String?

    private var profileId: String { ProfileNaming.id(for: name) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LK.Spacing.lg) {
                    Text("The new agent starts with the same model, keys, personality and skills as your default agent. You can change it on the Hermes computer.")
                        .font(LK.Typography.callout)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: LK.Spacing.xs) {
                        Text("Name").font(LK.Typography.captionStrong).foregroundStyle(.secondary)
                        LKTextField("e.g. Research Assistant", text: $name)
                            .autocorrectionDisabled()
                        if !name.isEmpty {
                            Text(profileId.isEmpty
                                 ? "Use letters or numbers in the name."
                                 : "Saved on \(instanceName) as “\(profileId)”.")
                                .font(LK.Typography.caption)
                                .foregroundStyle(profileId.isEmpty ? AnyShapeStyle(LK.Palette.danger) : AnyShapeStyle(.secondary))
                        }
                    }

                    VStack(alignment: .leading, spacing: LK.Spacing.xs) {
                        Text("What is it for? (optional)").font(LK.Typography.captionStrong).foregroundStyle(.secondary)
                        LKTextField("e.g. Finds and summarises sources", text: $purpose, axis: .vertical)
                    }

                    if let failure {
                        LKNotice(.warning, failure)
                    }
                }
                .padding(LK.Spacing.lg)
            }
            .lkScreenBackground()
            .navigationTitle("Add Agent")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .safeAreaBar(edge: .bottom) {
                LKPrimaryButton("Create Agent", systemImage: "plus") { create() }
                    .disabled(profileId.isEmpty || creating)
                    .padding(.horizontal, LK.Spacing.lg)
                    .padding(.vertical, LK.Spacing.sm)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(creating)
                }
            }
            .overlay {
                if creating {
                    LKBlockingProgress("Creating \(name.trimmingCharacters(in: .whitespaces))…")
                }
            }
            .interactiveDismissDisabled(creating)
        }
    }

    private func create() {
        creating = true
        failure = nil
        Task {
            defer { creating = false }
            do {
                let created = try await gateway.createProfile(name: name, description: purpose)
                onCreated(created)
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
