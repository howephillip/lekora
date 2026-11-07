import SwiftUI

#if os(iOS)
@main
#endif
public struct LekoraApp: App {
    @StateObject private var gateway = GatewayClient()
    @Environment(\.scenePhase) private var scenePhase

    public init() {}

    public var body: some Scene {
        WindowGroup {
            ContentView(gateway: gateway)
                .onOpenURL { url in
                    handleIncomingURL(url)
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        // Reconnect or verify connection upon returning to the foreground
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
            WalkingSkeletonPingView(
                gateway: gateway,
                instanceName: instanceName,
                profileName: profileName
            )
        default:
            SetupWizardView(gateway: gateway)
        }
    }
}
