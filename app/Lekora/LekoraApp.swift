import SwiftUI

#if os(iOS)
@main
#endif
public struct LekoraApp: App {
    @StateObject private var hosts = HostsModel()
    @Environment(\.scenePhase) private var scenePhase

    public init() {}

    public var body: some Scene {
        WindowGroup {
            ContentView(hosts: hosts)
                .onOpenURL { url in
                    handleIncomingURL(url)
                }
                .task {
                    // Launch: go straight back to every paired computer, skipping the wizard.
                    await hosts.resumeAll()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    // iOS drops the sockets while the app is in the background.
                    // resumeSavedSession does nothing if already connected or connecting.
                    if newPhase == .active {
                        Task { await hosts.resumeAll() }
                    } else if newPhase == .background {
                        hosts.saveCachesNow()
                    }
                }
        }
    }

    private func handleIncomingURL(_ url: URL) {
        guard url.scheme == "lekora-pair" else { return }
        hosts.handlePairingPayload(url.absoluteString)
    }
}

/// No computer yet: the setup wizard. One computer: as before (its agents, or choosing
/// agents, or reconnecting). Several: the agents list, which copes with any of them
/// being offline (docs/multiple-computers.md).
public struct ContentView: View {
    @ObservedObject public var hosts: HostsModel

    public init(hosts: HostsModel) {
        self.hosts = hosts
    }

    /// The agents list. Always the same branch below, so adding a second computer (or a
    /// reconnect) keeps the open chat and sheets.
    private var showsAgents: Bool {
        if hosts.hasSeveral { return true }
        guard let gateway = hosts.clients.first else { return false }
        switch gateway.state {
        case .connected:
            return !gateway.needsProfileChoice
        case .disconnected, .probing, .connecting:
            return gateway.hasCachedChats
        default:
            return false
        }
    }

    public var body: some View {
        if showsAgents {
            AgentsHomeView(hosts: hosts)
        } else if let gateway = hosts.clients.first, case .connected = gateway.state {
            ChooseProfilesView(gateway: gateway, mode: .setup)
        } else if let gateway = hosts.clients.first, let host = gateway.savedHost {
            ReconnectingView(gateway: gateway, host: host)
        } else {
            SetupWizardView(gateway: hosts.pairing, notice: hosts.notice)
        }
    }
}
