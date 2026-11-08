import SwiftUI

/// "Choose Agents": which Hermes profiles this phone uses. The last setup step after
/// pairing (skipped when the host has only one agent), and reachable later from the
/// chat's agent menu.
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

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: LK.Spacing.xl) {
                    header
                    VStack(spacing: LK.Spacing.sm) {
                        ForEach(gateway.profiles) { profile in
                            row(profile)
                        }
                    }
                }
                .padding(.horizontal, LK.Spacing.lg)
                .padding(.vertical, LK.Spacing.xl)
            }
            .lkScreenBackground()
            .safeAreaBar(edge: .bottom) {
                VStack(spacing: LK.Spacing.xs) {
                    LKPrimaryButton(mode == .setup ? "Continue" : "Done") {
                        gateway.chooseProfiles(Array(selected))
                        if mode == .edit { dismiss() }
                    }
                    .disabled(selected.isEmpty)
                    Text(selected.isEmpty ? "Choose at least one agent." : "You can change this later from the agent menu in the chat.")
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
        }
    }

    private var header: some View {
        VStack(spacing: LK.Spacing.sm) {
            Image(systemName: "person.2.wave.2")
                .font(.system(size: LK.Size.heroIcon))
                .foregroundStyle(LK.Palette.accent.gradient)
                .padding(.bottom, LK.Spacing.xs)
            Text("Choose Your Agents")
                .font(LK.Typography.largeTitle)
                .multilineTextAlignment(.center)
            Text("Pick which agents on \(instanceName) you want to chat with on this iPhone.")
                .font(LK.Typography.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, mode == .setup ? LK.Spacing.lg : 0)
    }

    private func row(_ profile: ProfileData) -> some View {
        let isOn = selected.contains(profile.profile_id)
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
                    } else if profile.name != profile.profile_id {
                        Text(profile.profile_id)
                            .font(LK.Typography.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(isOn ? AnyShapeStyle(LK.Palette.accent) : AnyShapeStyle(.tertiary))
            }
            .padding(LK.Spacing.md)
            .background(LK.Surface.raised, in: RoundedRectangle(cornerRadius: LK.Radius.card, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
