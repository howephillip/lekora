import SwiftUI

extension View {
    /// The standard screen background: base surface with a soft accent wash at the top,
    /// which also gives Liquid Glass controls some colour to pick up.
    public func lkScreenBackground() -> some View {
        background {
            ZStack {
                Rectangle().fill(LK.Surface.base)
                LinearGradient(
                    colors: [LK.Palette.accent.opacity(0.14), LK.Palette.accent.opacity(0)],
                    startPoint: .top,
                    endPoint: .center
                )
            }
            .ignoresSafeArea()
        }
    }
}

/// Grouped content on a raised surface.
public struct LKCard<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .padding(LK.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LK.Surface.raised, in: RoundedRectangle(cornerRadius: LK.Radius.card, style: .continuous))
    }
}

/// An inline message about connection state: in progress, a problem, or information.
public struct LKNotice: View {
    public enum Kind {
        case progress
        case warning
        case info
    }

    private let kind: Kind
    private let message: String

    public init(_ kind: Kind, _ message: String) {
        self.kind = kind
        self.message = message
    }

    public var body: some View {
        HStack(alignment: .top, spacing: LK.Spacing.md) {
            switch kind {
            case .progress:
                ProgressView()
            case .warning:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(LK.Palette.warning)
            case .info:
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(LK.Palette.accent)
            }
            Text(message)
                .font(LK.Typography.callout)
                .foregroundStyle(kind == .progress ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(LK.Spacing.lg)
        .background(LK.Surface.raised, in: RoundedRectangle(cornerRadius: LK.Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Covers the screen while something must finish before the user continues.
public struct LKBlockingProgress: View {
    private let title: String

    public init(_ title: String) {
        self.title = title
    }

    public var body: some View {
        ZStack {
            Color.black.opacity(0.2).ignoresSafeArea()
            VStack(spacing: LK.Spacing.md) {
                ProgressView()
                Text(title)
                    .font(LK.Typography.callout)
            }
            .padding(LK.Spacing.xl)
            .glassEffect(LK.Glass.bar, in: RoundedRectangle(cornerRadius: LK.Radius.card, style: .continuous))
        }
        .accessibilityElement(children: .combine)
    }
}
