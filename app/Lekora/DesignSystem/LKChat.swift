import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

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
        /// The agent is still writing this reply: show a cursor at the end.
        case streaming
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

    /// Agents write Markdown: show **bold**, *italic*, `code` and links, keep line breaks,
    /// and drop blank lines around the text. The user's own text is shown exactly as typed.
    private var rendered: AttributedString {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = isUser ? AttributedString(trimmed) : Self.markdown(trimmed)
        if delivery == .streaming {
            result += AttributedString(" ▍")
        }
        return result
    }

    static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        // Headings ("## Report") aren't inline Markdown: show them as bold lines.
        let headed = text.replacingOccurrences(of: #"(?m)^\s{0,3}#{1,6}\s+(.+?)\s*#*\s*$"#,
                                               with: "**$1**", options: .regularExpression)
        return (try? AttributedString(markdown: headed, options: options)) ?? AttributedString(text)
    }

    public var body: some View {
        HStack {
            if isUser { Spacer(minLength: LK.Size.bubbleSideMargin) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: LK.Spacing.xs) {
                Text(rendered)
                    .font(LK.Typography.body)
                    .textSelection(.enabled)
                    .foregroundStyle(isUser ? LK.Palette.onAccent : .primary)
                    .padding(.horizontal, LK.Spacing.md + LK.Spacing.xxs)
                    .padding(.vertical, LK.Spacing.sm + 1)
                    .background(isUser ? LK.Surface.accent : LK.Surface.inset,
                                in: RoundedRectangle(cornerRadius: LK.Radius.bubble, style: .continuous))
                    .opacity(delivery == .sending ? 0.6 : 1)

                switch delivery {
                case .delivered, .streaming:
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
    /// Before the text field, e.g. the + for photos and files (docs/files.md).
    private let accessory: AnyView?

    public init(_ placeholder: String, text: Binding<String>, canSend: Bool,
                focus: FocusState<Bool>.Binding, accessory: AnyView? = nil, onSend: @escaping () -> Void) {
        self.placeholder = placeholder
        self._text = text
        self.canSend = canSend
        self.focus = focus
        self.accessory = accessory
        self.onSend = onSend
    }

    public var body: some View {
        GlassEffectContainer(spacing: LK.Spacing.sm) {
            HStack(alignment: .bottom, spacing: LK.Spacing.sm) {
                if let accessory { accessory }
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

/// Shown while an agent works: softly pulsing dots (like iMessage), what it's doing when
/// Hermes says ("Bruce is searching the web…"), and how long it has been at it.
public struct LKTypingIndicator: View {
    private let status: String?
    private let since: Date?

    public init(status: String? = nil, since: Date? = nil) {
        self.status = status
        self.since = since
    }

    public var body: some View {
        HStack {
            HStack(spacing: LK.Spacing.sm) {
                LKTypingDots()
                if let line = statusLine {
                    Text(line)
                        .font(LK.Typography.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .contentTransition(.opacity)
                        .animation(.easeInOut(duration: 0.25), value: line)
                }
            }
            .padding(.horizontal, LK.Spacing.md + LK.Spacing.xxs)
            .padding(.vertical, LK.Spacing.md)
            .background(LK.Surface.inset, in: RoundedRectangle(cornerRadius: LK.Radius.bubble, style: .continuous))

            Spacer(minLength: LK.Size.bubbleSideMargin)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(statusLine.map { "Agent is working: \($0)" } ?? "Agent is typing")
    }

    /// "Searching the web · 3 min"; elapsed time from the first minute on.
    private var statusLine: String? {
        var parts: [String] = []
        if let status, !status.isEmpty { parts.append(status) }
        if let since {
            let minutes = Int(Date().timeIntervalSince(since) / 60)
            if minutes >= 1 { parts.append("\(minutes) min") }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Three dots that fade and swell in a continuous wave, redrawn every frame.
public struct LKTypingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    let level = reduceMotion ? 0.6 : Self.level(time: time, index: index)
                    Circle()
                        .frame(width: 8, height: 8)
                        .scaleEffect(0.8 + 0.2 * level)
                        .opacity(0.3 + 0.7 * level)
                }
            }
            .foregroundStyle(.secondary)
        }
        .frame(height: 10)
    }

    /// 0…1: a smooth wave that passes from dot to dot every 1.3 s.
    static func level(time: TimeInterval, index: Int) -> Double {
        let period = 1.3
        let phase = (time / period) * 2 * .pi - Double(index) * 0.75
        let wave = (sin(phase) + 1) / 2
        return wave * wave * (3 - 2 * wave)  // ease in and out at the peaks
    }
}

/// Hermes' own notices ("Gateway online…"): a quiet centered line, not a chat bubble.
public struct LKSystemNotice: View {
    private let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        // Hermes' notices can be a few lines (e.g. after switching models); code marks are
        // dropped so the line reads as one piece.
        Text(LKMessageBubble.markdown(text.trimmingCharacters(in: .whitespacesAndNewlines)
                                        .replacingOccurrences(of: "`", with: "")))
            .font(LK.Typography.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .lineLimit(8)
            .truncationMode(.tail)
            .textSelection(.enabled)
            .padding(.horizontal, LK.Spacing.xl)
            .padding(.vertical, LK.Spacing.xs)
            .frame(maxWidth: .infinity)
    }
}

// MARK: - Unread dot (docs/chat-history.md)

/// The blue "new messages" dot, as in Messages.
public struct LKUnreadDot: View {
    public init() {}

    public var body: some View {
        Circle()
            .fill(LK.Palette.accent)
            .frame(width: 8, height: 8)
    }

    /// The dot for menu rows. Menus draw SF Symbols in the text colour, so the image is
    /// pre-coloured to stay blue.
    public static var menuIcon: Image {
        #if canImport(UIKit)
        if let dot = UIImage(systemName: "circle.fill")?
            .withTintColor(.systemBlue, renderingMode: .alwaysOriginal) {
            return Image(uiImage: dot)
        }
        #endif
        return Image(systemName: "circle.fill")
    }
}

// MARK: - Drag left to see times

#if canImport(UIKit)
/// A pan that only starts for a leftward, mostly-horizontal drag, so vertical scrolling and
/// the system's swipe-right-to-go-back keep working. Reports how far left (0…) it is.
public struct LKLeftwardPan: UIGestureRecognizerRepresentable {
    private let onChange: (CGFloat) -> Void
    private let onEnd: () -> Void

    public init(onChange: @escaping (CGFloat) -> Void, onEnd: @escaping () -> Void) {
        self.onChange = onChange
        self.onEnd = onEnd
    }

    public func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    public func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    public func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        switch pan.state {
        case .began, .changed:
            onChange(max(0, -pan.translation(in: pan.view).x))
        case .ended, .cancelled, .failed:
            onEnd()
        default:
            break
        }
    }

    public final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        public func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return velocity.x < 0 && abs(velocity.x) > abs(velocity.y)
        }

        public func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                                      shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
#endif
