import SwiftUI

/// Your paired Hermes computers: whether each is connected, add another, rename or forget
/// one (docs/multiple-instances.md). Opened from "Hermes Instances…" on the agents list.
struct ComputersView: View {
    @ObservedObject var hosts: HostsModel
    @Environment(\.dismiss) private var dismiss
    @State private var adding = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(hosts.clients) { client in
                        NavigationLink {
                            ComputerDetailView(hosts: hosts, gateway: client)
                        } label: {
                            ComputerRow(gateway: client)
                        }
                    }
                } footer: {
                    Text("Each Hermes instance connects on its own: if one is offline, the others keep working.")
                }
                Section {
                    Button {
                        adding = true
                    } label: {
                        Label("Add Hermes Instance", systemImage: "plus.circle.fill")
                            .font(LK.Typography.headline)
                            .foregroundStyle(LK.Palette.accent)
                    }
                }
            }
            .navigationTitle("Hermes Instances")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $adding) {
                AddComputerView(hosts: hosts)
            }
        }
    }
}

/// A computer in the list: its name, and whether it's connected.
private struct ComputerRow: View {
    @ObservedObject var gateway: GatewayClient

    var body: some View {
        HStack(spacing: LK.Spacing.md) {
            Image(systemName: "server.rack")
                .font(.title3)
                .foregroundStyle(LK.Palette.accent)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(gateway.savedHost?.instanceName ?? "Hermes")
                    .font(LK.Typography.headline)
                ComputerStatus(gateway: gateway)
            }
        }
        .padding(.vertical, 2)
    }
}

/// "Connected · 3 agents", "Not connected", "Connecting…".
private struct ComputerStatus: View {
    @ObservedObject var gateway: GatewayClient

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
        }
        .font(LK.Typography.footnote)
        .foregroundStyle(.secondary)
    }

    private var agents: String {
        let count = gateway.enabledProfiles.count
        return count == 1 ? "1 agent" : "\(count) agents"
    }

    private var text: String {
        switch gateway.state {
        case .connected: return "Connected · \(agents)"
        case .disconnected, .error: return "Not connected · \(agents)"
        default: return "Connecting…"
        }
    }

    private var color: Color {
        switch gateway.state {
        case .connected: return LK.Palette.success
        case .disconnected, .error: return .secondary
        default: return LK.Palette.warning
        }
    }
}

/// One computer: rename it, see why it isn't connected, or forget it.
private struct ComputerDetailView: View {
    @ObservedObject var hosts: HostsModel
    @ObservedObject var gateway: GatewayClient
    @Environment(\.dismiss) private var dismiss
    @State private var renaming = false
    @State private var newName = ""
    @State private var failure: String?
    @State private var confirmingForget = false
    @State private var forgetMessage: String?

    private var name: String { gateway.savedHost?.instanceName ?? "Hermes" }

    private var isConnected: Bool {
        if case .connected = gateway.state { return true }
        return false
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Name") { Text(name) }
                Button("Rename…") {
                    newName = name
                    renaming = true
                }
                .disabled(!isConnected)
            } footer: {
                Text(isConnected ? "The name is saved on the Hermes instance, so all your phones show it."
                                 : "Connect to this instance to rename it.")
            }
            Section {
                ComputerStatus(gateway: gateway)
                if case .error(let reason) = gateway.state {
                    Text(reason).font(LK.Typography.footnote).foregroundStyle(.secondary)
                }
                if !isConnected {
                    Button("Try Again") { Task { await gateway.resumeSavedSession() } }
                }
            }
            if let failure {
                Text(failure).font(LK.Typography.footnote).foregroundStyle(LK.Palette.danger)
            }
            Section {
                Button("Forget This Instance", role: .destructive) { confirmingForget = true }
            } footer: {
                Text("Only this instance is removed from the phone; your others stay. Its chats stay on the instance.")
            }
        }
        .navigationTitle(name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .alert("Rename Instance", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Save") { rename() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Forget \(name)?", isPresented: $confirmingForget, titleVisibility: .visible) {
            Button("Disconnect and Forget", role: .destructive) {
                Task {
                    forgetMessage = await hosts.forget(gateway)
                    if forgetMessage == nil { dismiss() }
                }
            }
        } message: {
            Text("This phone will disconnect from \(name) and be removed from its device list. To connect again you'll need a new pairing code from that Hermes instance. Your other instances stay connected.")
        }
        .alert("Forgotten", isPresented: Binding(get: { forgetMessage != nil }, set: { if !$0 { forgetMessage = nil; dismiss() } })) {
            Button("OK") {}
        } message: {
            Text(forgetMessage ?? "")
        }
        .overlay {
            if gateway.isForgetting {
                LKBlockingProgress("Forgetting \(name)…")
            }
        }
    }

    private func rename() {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != name else { return }
        failure = nil
        Task {
            do {
                try await gateway.renameInstance(trimmed)
            } catch {
                failure = "Couldn't rename it: \(error.localizedDescription)"
            }
        }
    }
}

/// Pairing another computer: the setup wizard, then choosing its agents.
struct AddComputerView: View {
    @ObservedObject var hosts: HostsModel
    /// The client doing this pairing (the model makes a new one for the next pairing).
    @StateObject private var client: GatewayClientBox
    @Environment(\.dismiss) private var dismiss

    init(hosts: HostsModel) {
        self.hosts = hosts
        _client = StateObject(wrappedValue: GatewayClientBox(hosts.pairing))
    }

    var body: some View {
        AddComputerSteps(gateway: client.gateway, done: { dismiss() })
    }
}

/// Keeps the same pairing client for the whole sheet.
final class GatewayClientBox: ObservableObject {
    let gateway: GatewayClient
    init(_ gateway: GatewayClient) { self.gateway = gateway }
}

private struct AddComputerSteps: View {
    @ObservedObject var gateway: GatewayClient
    let done: () -> Void

    var body: some View {
        Group {
            if case .connected = gateway.state {
                if gateway.needsProfileChoice {
                    ChooseProfilesView(gateway: gateway, mode: .setup)
                } else {
                    Color.clear.onAppear(perform: done)
                }
            } else {
                SetupWizardView(gateway: gateway, addingComputer: true)
            }
        }
    }
}
