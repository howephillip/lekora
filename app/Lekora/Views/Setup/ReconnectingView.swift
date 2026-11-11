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

                LKPrimaryButton("Try Again", systemImage: "arrow.clockwise") {
                    Task { await gateway.resumeSavedSession() }
                }
            }

            Spacer()

            LKSecondaryButton("Forget This Computer", systemImage: "xmark.circle", role: .destructive) {
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
            Text("This phone will stop connecting to it and ask it to remove this phone from its device list. To connect again you'll need a new pairing code from that computer.")
        }
        .overlay {
            if gateway.isForgetting {
                LKBlockingProgress("Forgetting \(host.instanceName)…")
            }
        }
    }
}
