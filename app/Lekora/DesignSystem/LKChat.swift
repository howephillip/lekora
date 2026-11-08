import SwiftUI

/// One chat bubble. The user's sit on the right in the accent colour; the agent's on the
/// left on an inset surface. Bubbles are content, so they are solid, not glass.
public struct LKMessageBubble: View {
    public enum Sender {
        case user
        case agent
    }

    public enum Delivery: Equatable {
        case delivered
        case sending
        case failed(String)
    }

    private let text: String
    private let sender: Sender
    private let delivery: Delivery

    public init(_ text: String, from sender: Sender, delivery: Delivery = .delivered) {
        self.text = text
        self.sender = sender
        self.delivery = delivery
    }

    private var isUser: Bool { sender == .user }

    public var body: some View {
        HStack {
            if isUser { Spacer(minLength: LK.Size.bubbleSideMargin) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: LK.Spacing.xs) {
                Text(text)
                    .font(LK.Typography.body)
                    .textSelection(.enabled)
                    .foregroundStyle(isUser ? LK.Palette.onAccent : .primary)
                    .padding(.horizontal, LK.Spacing.md + LK.Spacing.xxs)
                    .padding(.vertical, LK.Spacing.sm + 1)
                    .background(isUser ? LK.Surface.accent : LK.Surface.inset,
                                in: RoundedRectangle(cornerRadius: LK.Radius.bubble, style: .continuous))
                    .opacity(delivery == .sending ? 0.6 : 1)

                switch delivery {
                case .delivered:
                    EmptyView()
                case .sending:
                    Text("Sending…")
                        .font(LK.Typography.caption)
                        .foregroundStyle(.secondary)
                case .failed(let reason):
                    Label("Not delivered: \(reason)", systemImage: "exclamationmark.circle")
                        .font(LK.Typography.caption)
                        .foregroundStyle(LK.Palette.danger)
                }
            }

            if !isUser { Spacer(minLength: LK.Size.bubbleSideMargin) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isUser ? "You: \(text)" : text)
    }
}

/// The floating message bar: a glass text field and a send button that share one
/// glass container, so they read as a single control.
public struct LKComposer: View {
    private let placeholder: String
    @Binding private var text: String
    private let canSend: Bool
    private let onSend: () -> Void
    private var focus: FocusState<Bool>.Binding

    public init(_ placeholder: String, text: Binding<String>, canSend: Bool,
                focus: FocusState<Bool>.Binding, onSend: @escaping () -> Void) {
        self.placeholder = placeholder
        self._text = text
        self.canSend = canSend
        self.focus = focus
        self.onSend = onSend
    }

    public var body: some View {
        GlassEffectContainer(spacing: LK.Spacing.sm) {
            HStack(alignment: .bottom, spacing: LK.Spacing.sm) {
                LKTextField(placeholder, text: $text, style: .glass, axis: .vertical)
                    .focused(focus)

                Button(action: onSend) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 18, weight: .bold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .tint(LK.Palette.accent)
                .disabled(!canSend)
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, LK.Spacing.lg)
        .padding(.vertical, LK.Spacing.sm)
    }
}

/// An agent's initial in a tinted circle. Hermes profiles have no pictures yet.
public struct LKAgentAvatar: View {
    private let name: String
    private let size: CGFloat

    public init(_ name: String, size: CGFloat = 40) {
        self.name = name
        self.size = size
    }

    public var body: some View {
        Text(name.first.map { String($0).uppercased() } ?? "?")
            .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
            .foregroundStyle(LK.Palette.accent)
            .frame(width: size, height: size)
            .background(LK.Palette.accent.opacity(0.15), in: Circle())
            .accessibilityHidden(true)
    }
}
