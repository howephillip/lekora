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

    public var body: some View {
        switch gateway.state {
        case .connected(let instanceName, let profileName):
            if gateway.needsProfileChoice {
                ChooseProfilesView(gateway: gateway, mode: .setup)
            } else {
                WalkingSkeletonPingView(
                    gateway: gateway,
                    instanceName: instanceName,
                    profileName: profileName
                )
            }
        case .disconnected, .probing, .connecting:
            if gateway.hasCachedChats {
                // The last known chats, while reconnecting (docs/chat-history.md).
                WalkingSkeletonPingView(
                    gateway: gateway,
                    instanceName: gateway.savedHost?.instanceName ?? "",
                    profileName: gateway.activeProfile?.name ?? ""
                )
            } else if let host = gateway.savedHost {
                ReconnectingView(gateway: gateway, host: host)
            } else {
                SetupWizardView(gateway: gateway)
            }
        default:
            if let host = gateway.savedHost {
                ReconnectingView(gateway: gateway, host: host)
            } else {
                SetupWizardView(gateway: gateway)
            }
        }
    }
}
