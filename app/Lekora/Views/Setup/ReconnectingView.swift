import SwiftUI

/// Shown while a paired host is being reconnected, or when it can't be reached.
/// Keeps the pairing so the user isn't pushed into re-pairing over a network blip.
public struct ReconnectingView: View {
    @ObservedObject public var gateway: GatewayClient
    public let host: SavedHost

    @State private var confirmingForget = false

    public init(gateway: GatewayClient, host: SavedHost) {
        self.gateway = gateway
        self.host = host
    }

    private var isWorking: Bool {
        switch gateway.state {
        case .probing, .pairing, .connecting:
            return true
        default:
            return false
        }
    }

    private var problem: String? {
        switch gateway.state {
        case .error(let reason):
            return reason
        case .disconnected:
            return "Not connected to \(host.instanceName)."
        default:
            return nil
        }
    }

    public var body: some View {
        VStack(spacing: LK.Spacing.xl) {
            Spacer()

            VStack(spacing: LK.Spacing.md) {
                Image(systemName: isWorking ? "antenna.radiowaves.left.and.right" : "wifi.exclamationmark")
                    .font(.system(size: LK.Size.heroIcon))
                    .foregroundStyle(isWorking ? AnyShapeStyle(LK.Palette.accent.gradient) : AnyShapeStyle(LK.Palette.warning))
                    .symbolEffect(.variableColor.iterative, isActive: isWorking)

                Text(host.instanceName)
                    .font(LK.Typography.title)

                LKStatusBadge(isWorking ? .connecting : .offline,
                              label: isWorking ? "Reconnecting" : "Not connected")
            }

            if !isWorking, let problem {
                LKNotice(.warning, problem)
                LKTailscaleHelp(endpoints: host.endpoints)

                LKPrimaryButton("Try Again", systemImage: "arrow.clockwise") {
                    Task { await gateway.resumeSavedSession() }
                }
            }

            Spacer()

            LKSecondaryButton("Forget This Instance", systemImage: "xmark.circle", role: .destructive) {
                confirmingForget = true
            }
        }
        .padding(.horizontal, LK.Spacing.lg)
        .padding(.bottom, LK.Spacing.lg)
        .lkScreenBackground()
        .confirmationDialog(
            "Forget \(host.instanceName)?",
            isPresented: $confirmingForget,
            titleVisibility: .visible
        ) {
            Button("Disconnect and Forget", role: .destructive) {
                Task { await gateway.forgetHost() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This phone will stop connecting to it and ask it to remove this phone from its device list. To connect again you'll need a new pairing code from that Hermes instance.")
        }
        .overlay {
            if gateway.isForgetting {
                LKBlockingProgress("Forgetting \(host.instanceName)…")
            }
        }
    }
}

/// When the instance can't be reached (docs/tailscale.md): whether Tailscale is the missing piece, with a
/// button to Tailscale (its app, or the App Store when it isn't installed).
struct LKTailscaleHelp: View {
    /// The addresses this phone knows for the instance.
    let endpoints: [String]
    @Environment(\.openURL) private var openURL
    @State private var onTailscale = LKRoute.phoneOnTailscale()

    private var instanceOnTailscale: Bool { endpoints.contains { LKRoute.of($0) == .tailscale } }

    var body: some View {
        Group {
            if instanceOnTailscale && !onTailscale {
                VStack(spacing: LK.Spacing.sm) {
                    Text("Away from home? This phone isn't on Tailscale right now. Turn it on, then try again.")
                        .font(LK.Typography.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    LKSecondaryButton("Turn On Tailscale", systemImage: "network") { openTailscale() }
                }
            } else if !instanceOnTailscale {
                VStack(spacing: LK.Spacing.sm) {
                    Text("This instance can only be reached on its home network. To use Lekora anywhere, install Tailscale on the Hermes machine and this phone (same account); Lekora finds the new address by itself.")
                        .font(LK.Typography.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    LKSecondaryButton("Get Tailscale", systemImage: "arrow.down.app") { openURL(LKRoute.tailscaleAppStore) }
                }
            }
        }
        .onAppear { onTailscale = LKRoute.phoneOnTailscale() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            onTailscale = LKRoute.phoneOnTailscale()
        }
    }

    private func openTailscale() {
        openURL(LKRoute.tailscaleApp) { opened in
            if !opened { openURL(LKRoute.tailscaleAppStore) }
        }
    }
}
