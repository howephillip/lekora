import SwiftUI

// Xcode previews of the design system, for checking the look without a device.

#Preview("Components") {
    ScrollView {
        VStack(alignment: .leading, spacing: LK.Spacing.lg) {
            HStack {
                LKStatusBadge(.connected)
                LKStatusBadge(.connecting)
                LKStatusBadge(.offline)
            }
            LKCard {
                Text("A card on the raised surface.")
                    .font(LK.Typography.callout)
            }
            LKNotice(.progress, "Looking for your Hermes computer…")
            LKNotice(.warning, "Can't reach Hermes right now.")
            LKPrimaryButton("Scan QR Code", systemImage: "qrcode.viewfinder") {}
            LKSecondaryButton("Paste", systemImage: "doc.on.clipboard") {}
            LKSecondaryButton("Forget Host", systemImage: "xmark.circle", role: .destructive) {}
            LKTextField("lekora-pair://…", text: .constant(""))
        }
        .padding(LK.Spacing.lg)
    }
    .lkScreenBackground()
}

#Preview("Chat bubbles") {
    @Previewable @State var draft = ""
    @Previewable @FocusState var focused: Bool
    ScrollView {
        VStack(spacing: LK.Spacing.sm) {
            LKMessageBubble("What's on my calendar tomorrow?", from: .user)
            LKMessageBubble("You have two meetings: a design review at 10:00 and a call with Sam at 14:30.", from: .agent)
            LKMessageBubble("Move the call to Friday", from: .user, delivery: .sending)
            LKMessageBubble("Thanks!", from: .user, delivery: .failed("The agent could not take this message"))
        }
        .padding(LK.Spacing.lg)
    }
    .lkScreenBackground()
    .safeAreaBar(edge: .bottom) {
        LKComposer("Message Hermes Assistant", text: $draft, canSend: false, focus: $focused) {}
    }
}

#Preview("Setup screen") {
    SetupWizardView(gateway: GatewayClient(keychain: PreviewCredentialStore()))
}

/// Keeps previews away from the real Keychain.
private final class PreviewCredentialStore: CredentialStore {
    func save(key: String, value: String) throws {}
    func get(key: String) throws -> String? { nil }
    func delete(key: String) throws {}
}

#Preview("Streaming") {
    ScrollView {
        VStack(spacing: LK.Spacing.sm) {
            LKSystemNotice("♻️ Gateway online — Hermes is back and ready.")
            LKMessageBubble("I need you to find me the best ramen place in Cedar Park and explain why it's the best", from: .user)
            LKMessageBubble("\n\nCarl's on it — researching Cedar Park ramen now, back with the pick shortly.\n\n", from: .agent)
            LKSystemNotice("✅ Background task finished — `cd /home/phillip/.hermes/cache/scratch && hermes -p carl -z \"$(cat carl-ramen-c…` (7m 19s)")
            LKMessageBubble("**Ramen512** — 1420 Cypress Creek Rd Ste 300. 4.6 stars, the *highest* of the four.\n\nWhy it wins:\n- It's the only actual ramen shop in Cedar Park.\n- Everything's made downstairs — see [their menu](https://example.com).", from: .agent, delivery: .streaming)
            LKTypingIndicator(status: "Default is using browser_exec…", since: Date().addingTimeInterval(-12 * 60))
        }
        .padding(LK.Spacing.lg)
    }
    .lkScreenBackground()
}
