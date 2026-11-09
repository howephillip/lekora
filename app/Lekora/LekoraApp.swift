import SwiftUI

#if os(iOS)
@main
#endif
public struct LekoraApp: App {
    @StateObject private var gateway = GatewayClient(cacheStore: .standard)
    @Environment(\.scenePhase) private var scenePhase

    public init() {}

    public var body: some Scene {
        WindowGroup {
            ContentView(gateway: gateway)
                .onOpenURL { url in
                    handleIncomingURL(url)
                }
                .task {
                    // Launch: go straight back to the paired host, skipping the wizard.
                    await gateway.resumeSavedSession()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    // iOS drops the socket while the app is in the background.
                    // resumeSavedSession does nothing if already connected or connecting.
                    if newPhase == .active {
                        Task { await gateway.resumeSavedSession() }
                    } else if newPhase == .background {
                        gateway.saveCacheNow()
                    }
                }
        }
    }

    private func handleIncomingURL(_ url: URL) {
        guard url.scheme == "lekora-pair" else { return }
        gateway.handlePairingPayload(url.absoluteString)
    }
}

public struct ContentView: View {
    @ObservedObject public var gateway: GatewayClient

    public init(gateway: GatewayClient) {
        self.gateway = gateway
    }

    /// The agents list shows while connected, and while reconnecting when the last known
    /// chats are on the phone. One place in the view tree, so a reconnect keeps the open chat.
    private var showsAgents: Bool {
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
            AgentsHomeView(gateway: gateway)
        } else if case .connected = gateway.state {
            ChooseProfilesView(gateway: gateway, mode: .setup)
        } else if let host = gateway.savedHost {
            ReconnectingView(gateway: gateway, host: host)
        } else {
            SetupWizardView(gateway: gateway)
        }
    }
}
