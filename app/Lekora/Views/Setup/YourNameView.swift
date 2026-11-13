import SwiftUI

/// "Your Name" (docs/your-name.md): what your agents call you. Kept on each Hermes instance,
/// so it survives re-setup and a new phone; saved on every connected instance at once.
struct YourNameView: View {
    @ObservedObject var hosts: HostsModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var saving = false
    @State private var failure: String?

    /// Instances that can keep the name (connected, with a plugin new enough).
    private var able: [GatewayClient] { hosts.clients.filter { $0.userName != nil } }
    private var unreachable: [String] {
        hosts.clients.filter { $0.userName == nil }.map { $0.savedHost?.instanceName ?? "Hermes" }
    }
    private var cleaned: String { name.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Your name", text: $name)
                        .textContentType(.givenName)
                        .accessibilityLabel("Your name")
                } header: {
                    Text("What should your agents call you?")
                } footer: {
                    Text("Your agents see this name as the person they're talking to, instead of “Lekora”. Leave it empty if you'd rather not say.")
                }
                if !unreachable.isEmpty {
                    Section {
                        LKNotice(.warning, "Not saved on \(unreachable.joined(separator: ", ")) right now: it isn't connected, or its Lekora plugin needs updating.")
                    }
                }
                if let failure {
                    Section { LKNotice(.warning, failure) }
                }
            }
            .navigationTitle("Your Name")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(saving || able.isEmpty)
                }
            }
            .onAppear {
                name = able.compactMap(\.userName).first { !$0.isEmpty } ?? ""
            }
        }
    }

    private func save() {
        saving = true
        failure = nil
        Task {
            defer { saving = false }
            do {
                for client in able where client.userName != cleaned {
                    try await client.setUserName(cleaned)
                }
                dismiss()
            } catch {
                failure = "Couldn't save your name: \(error.localizedDescription)"
            }
        }
    }
}
