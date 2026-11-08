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
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: isWorking ? "antenna.radiowaves.left.and.right" : "wifi.exclamationmark")
                .font(.system(size: 44))
                .foregroundColor(isWorking ? .blue : .orange)

            Text(host.instanceName)
                .font(.title2)
                .fontWeight(.semibold)

            if isWorking {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Reconnecting…")
                        .foregroundColor(.secondary)
                }
            } else if let problem {
                Text(problem)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Button {
                    Task { await gateway.resumeSavedSession() }
                } label: {
                    Text("Try Again")
                        .font(.headline)
                        .frame(maxWidth: 240)
                        .padding(.vertical, 12)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
            }

            Spacer()

            Button("Forget Host", role: .destructive) {
                confirmingForget = true
            }
            .font(.footnote)
            .padding(.bottom, 24)
        }
        .confirmationDialog(
            "Forget \(host.instanceName)?",
            isPresented: $confirmingForget,
            titleVisibility: .visible
        ) {
            Button("Forget Host", role: .destructive) {
                Task { await gateway.forgetHost() }
            }
        } message: {
            Text("This phone will stop connecting to it and ask the host to remove it from its device list. To connect again you'll need a new pairing code from the Hermes machine.")
        }
        .overlay {
            if gateway.isForgetting {
                ForgettingOverlay()
            }
        }
    }
}

/// Covers the screen while Forget Host asks the host to remove this phone.
struct ForgettingOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                Text("Forgetting host…")
                    .font(.subheadline)
            }
            .padding(24)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }
}
