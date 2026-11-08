import SwiftUI

public struct SetupWizardView: View {
    @ObservedObject public var gateway: GatewayClient
    @State private var pairingCodeInput: String = ""
    @State private var showingScanner: Bool = false

    public init(gateway: GatewayClient) {
        self.gateway = gateway
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                VStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 48))
                        .foregroundColor(.blue)

                    Text("Pair with Hermes")
                        .font(.largeTitle)
                        .fontWeight(.bold)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("1. On the computer running Hermes, run the pair command: hermes lekora pair")
                        Text("2. Scan the QR code it shows, or copy the pairing link that starts with lekora-pair:// and paste it below.")
                        Text("3. Tap Connect. The link works once and expires after 30 minutes.")
                    }
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 24)
                }
                .padding(.top, 24)

                // Input & Action Area
                VStack(spacing: 16) {
                    Button(action: { showingScanner = true }) {
                        Label("Scan Host QR Code", systemImage: "qrcode.viewfinder")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                    }

                    HStack {
                        Rectangle().frame(height: 1).foregroundColor(Color.secondary.opacity(0.3))
                        Text("OR").font(.caption).foregroundColor(.secondary)
                        Rectangle().frame(height: 1).foregroundColor(Color.secondary.opacity(0.3))
                    }
                    .padding(.vertical, 4)

                    TextField("Paste pairing link or code here...", text: $pairingCodeInput)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif

                    HStack(spacing: 12) {
                        Button(action: pasteFromClipboard) {
                            Label("Paste", systemImage: "doc.on.clipboard")
                                .font(.subheadline)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(Color.secondary.opacity(0.15))
                                .cornerRadius(8)
                        }

                        Button(action: {
                            handlePairingPayload(pairingCodeInput)
                        }) {
                            Text("Connect")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(pairingCodeInput.isEmpty ? Color.gray : Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(8)
                        }
                        .disabled(pairingCodeInput.isEmpty)
                    }
                }
                .padding(.horizontal, 24)

                // Connection State Indicator
                connectionStatusSection
                    .padding(.horizontal, 24)

                Spacer()
            }
            .navigationTitle("Setup")
            .sheet(isPresented: $showingScanner) {
                ZStack {
                    QRScannerView { scannedCode in
                        self.pairingCodeInput = scannedCode
                        self.handlePairingPayload(scannedCode)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()

                    VStack {
                        HStack {
                            Spacer()
                            Button(action: { showingScanner = false }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 28))
                                    .foregroundColor(.white.opacity(0.8))
                                    .padding()
                            }
                        }
                        Spacer()
                        Text("Point camera at the QR code on your host")
                            .font(.footnote)
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.black.opacity(0.6))
                            .clipShape(Capsule())
                            .padding(.bottom, 30)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var connectionStatusSection: some View {
        switch gateway.state {
        case .probing:
            HStack(spacing: 12) {
                ProgressView()
                Text("Probing candidate endpoints (LAN & Tailscale)...")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        case .pairing:
            HStack(spacing: 12) {
                ProgressView()
                Text("Exchanging credentials with Hermes host...")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        case .connecting:
            HStack(spacing: 12) {
                ProgressView()
                Text("Connecting to WebSocket gateway...")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        case .error(let reason):
            VStack(alignment: .leading, spacing: 6) {
                Label("Connection Error", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundColor(.red)
                Text(reason)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.1))
            .cornerRadius(10)
        default:
            EmptyView()
        }
    }

    private func pasteFromClipboard() {
        #if os(iOS)
        if let string = UIPasteboard.general.string {
            self.pairingCodeInput = string
            handlePairingPayload(string)
        }
        #endif
    }

    public func handlePairingPayload(_ payload: String) {
        gateway.handlePairingPayload(payload)
    }
}
