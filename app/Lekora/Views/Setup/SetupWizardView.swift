import SwiftUI

public struct SetupWizardView: View {
    @ObservedObject public var gateway: GatewayClient
    /// Why the wizard is showing again (e.g. a computer no longer knows this phone).
    public var notice: String?
    /// Pairing another computer (from Computers), shown as a sheet with Cancel.
    public var addingComputer = false
    @Environment(\.dismiss) private var dismiss
    @State private var pairingCodeInput: String = ""
    @State private var showingScanner: Bool = false

    public init(gateway: GatewayClient, notice: String? = nil, addingComputer: Bool = false) {
        self.gateway = gateway
        self.notice = notice
        self.addingComputer = addingComputer
    }

    private var isWorking: Bool {
        switch gateway.state {
        case .probing, .pairing, .connecting:
            return true
        default:
            return false
        }
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: LK.Spacing.xl) {
                    hero
                    steps

                    LKPrimaryButton("Scan QR Code", systemImage: "qrcode.viewfinder") {
                        showingScanner = true
                    }
                    .disabled(isWorking)

                    pasteSection
                    connectionStatusSection
                }
                .padding(.horizontal, LK.Spacing.lg)
                .padding(.vertical, LK.Spacing.xl)
            }
            .scrollDismissesKeyboard(.interactively)
            .lkScreenBackground()
            .sheet(isPresented: $showingScanner) {
                scannerSheet
            }
            .toolbar {
                if addingComputer {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
        }
    }

    // MARK: - Sections

    private var hero: some View {
        VStack(spacing: LK.Spacing.sm) {
            Image(systemName: "sparkles")
                .font(.system(size: LK.Size.heroIcon))
                .foregroundStyle(LK.Palette.accent.gradient)
                .padding(.bottom, LK.Spacing.xs)
            Text(addingComputer ? "Add a Hermes Instance" : "Pair with Hermes")
                .font(LK.Typography.largeTitle)
            Text(addingComputer ? "Connect this iPhone to another Hermes instance. Your other instances stay connected."
                                : "Connect this iPhone to the computer running Hermes.")
                .font(LK.Typography.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, LK.Spacing.lg)
    }

    private var steps: some View {
        LKCard {
            VStack(alignment: .leading, spacing: LK.Spacing.md) {
                step(1) {
                    VStack(alignment: .leading, spacing: LK.Spacing.xs) {
                        Text("On the Hermes computer, run:")
                        Text("hermes lekora pair")
                            .font(LK.Typography.code)
                            .textSelection(.enabled)
                            .padding(.horizontal, LK.Spacing.sm)
                            .padding(.vertical, LK.Spacing.xs)
                            .background(LK.Surface.inset, in: RoundedRectangle(cornerRadius: LK.Radius.small, style: .continuous))
                    }
                }
                step(2) { Text("Scan the QR code it shows, or paste the link that starts with lekora-pair://.") }
                step(3) { Text("The code works once and expires after 30 minutes.") }
            }
            .font(LK.Typography.callout)
        }
    }

    private func step<Content: View>(_ number: Int, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: LK.Spacing.md) {
            Text("\(number)")
                .font(LK.Typography.captionStrong)
                .foregroundStyle(LK.Palette.onAccent)
                .frame(width: 22, height: 22)
                .background(LK.Palette.accent, in: Circle())
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var pasteSection: some View {
        VStack(spacing: LK.Spacing.md) {
            HStack(spacing: LK.Spacing.sm) {
                Rectangle().frame(height: 1).foregroundStyle(.quaternary)
                Text("or paste the link")
                    .font(LK.Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Rectangle().frame(height: 1).foregroundStyle(.quaternary)
            }

            LKTextField("lekora-pair://…", text: $pairingCodeInput)
                .submitLabel(.go)
                .onSubmit {  // Return connects (the keyboard can hide the Connect button)
                    if !pairingCodeInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !isWorking {
                        handlePairingPayload(pairingCodeInput)
                    }
                }
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif

            HStack(spacing: LK.Spacing.md) {
                LKSecondaryButton("Paste", systemImage: "doc.on.clipboard", action: pasteFromClipboard)
                LKPrimaryButton("Connect") {
                    handlePairingPayload(pairingCodeInput)
                }
                .disabled(pairingCodeInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)
            }
        }
    }

    @ViewBuilder
    private var connectionStatusSection: some View {
        switch gateway.state {
        case .probing:
            LKNotice(.progress, "Looking for your Hermes computer on this network and Tailscale…")
        case .pairing:
            LKNotice(.progress, "Pairing with Hermes…")
        case .connecting:
            LKNotice(.progress, "Connecting…")
        case .error(let reason):
            LKNotice(.warning, reason)
        default:
            if let notice { LKNotice(.warning, notice) }
        }
    }

    // MARK: - Scanner

    private var scannerSheet: some View {
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
                    Button {
                        showingScanner = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Close")
                }
                .padding(LK.Spacing.lg)

                Spacer()

                // Clear glass over the camera, with dimming for legibility (per Apple's guidance).
                Text("Point the camera at the QR code on your Hermes computer")
                    .font(LK.Typography.footnote)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, LK.Spacing.lg)
                    .padding(.vertical, LK.Spacing.sm)
                    .background(Color.black.opacity(0.35), in: Capsule())
                    .glassEffect(.clear, in: Capsule())
                    .padding(.horizontal, LK.Spacing.xl)
                    .padding(.bottom, LK.Spacing.xxl)
            }
        }
    }

    // MARK: - Actions

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
