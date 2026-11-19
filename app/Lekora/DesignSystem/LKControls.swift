import SwiftUI

// MARK: - Buttons

/// The main action on a screen: prominent Liquid Glass in the accent tint, full width.
public struct LKPrimaryButton: View {
    private let title: String
    private let systemImage: String?
    private let action: () -> Void

    public init(_ title: String, systemImage: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            LKButtonLabel(title: title, systemImage: systemImage)
        }
        .buttonStyle(.glassProminent)
        .tint(LK.Palette.accent)
        .controlSize(.large)
    }
}

/// Secondary actions: regular Liquid Glass. Pass `role: .destructive` for things like Forget Host.
public struct LKSecondaryButton: View {
    private let title: String
    private let systemImage: String?
    private let role: ButtonRole?
    private let action: () -> Void

    public init(_ title: String, systemImage: String? = nil, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.role = role
        self.action = action
    }

    public var body: some View {
        Button(role: role, action: action) {
            LKButtonLabel(title: title, systemImage: systemImage)
                .foregroundStyle(role == .destructive ? LK.Palette.danger : .primary)
        }
        .buttonStyle(.glass)
        .controlSize(.large)
    }
}

private struct LKButtonLabel: View {
    let title: String
    let systemImage: String?

    var body: some View {
        Group {
            if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        }
        .font(LK.Typography.headline)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Text input

/// A single text field. `.surface` sits in content (forms); `.glass` floats in a bar.
public struct LKTextField: View {
    public enum Style {
        case surface
        case glass
    }

    private let placeholder: String
    @Binding private var text: String
    private let style: Style
    private let axis: Axis
    /// Inside the field on the right, e.g. the message bar's mic or Send (as in Messages).
    private let trailing: AnyView?
    /// Set: Paste also takes photos and files (the message bar), which go here.
    private let onPaste: (([NSItemProvider]) -> Void)?
    private let focus: FocusState<Bool>.Binding?
    private let focusRequest: Int

    public init(_ placeholder: String, text: Binding<String>, style: Style = .surface, axis: Axis = .horizontal,
                trailing: AnyView? = nil, focus: FocusState<Bool>.Binding? = nil, focusRequest: Int = 0,
                onPaste: (([NSItemProvider]) -> Void)? = nil) {
        self.focusRequest = focusRequest
        self.placeholder = placeholder
        self._text = text
        self.style = style
        self.axis = axis
        self.trailing = trailing
        self.focus = focus
        self.onPaste = onPaste
    }

    @ViewBuilder
    private var input: some View {
        #if canImport(UIKit)
        if let onPaste {
            LKPasteTextView(placeholder: placeholder, text: $text, focus: focus, focusRequest: focusRequest,
                            maxLines: 5, onPaste: onPaste)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
        } else {
            plainField
        }
        #else
        plainField
        #endif
    }

    @ViewBuilder
    private var plainField: some View {
        if let focus {
            TextField(placeholder, text: $text, axis: axis)
                .font(LK.Typography.body)
                .lineLimit(1...5)
                .padding(.vertical, LK.Spacing.md)
                .focused(focus)
        } else {
            TextField(placeholder, text: $text, axis: axis)
                .font(LK.Typography.body)
                .lineLimit(1...5)
                .padding(.vertical, LK.Spacing.md)
        }
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: LK.Radius.field, style: .continuous)
        let field = HStack(alignment: .bottom, spacing: LK.Spacing.xs) {
            input
            if let trailing {
                trailing
                    .padding(.vertical, (LK.Spacing.md * 2 + 22 - 32) / 2)  // centred on the first line
            }
        }
        .padding(.leading, LK.Spacing.lg)
        .padding(.trailing, trailing == nil ? LK.Spacing.lg : LK.Spacing.xs + 2)

        switch style {
        case .surface:
            field.background(LK.Surface.inset, in: shape)
        case .glass:
            field.glassEffect(LK.Glass.control, in: shape)
        }
    }
}

// MARK: - Status

/// A small glass capsule showing connection state.
public struct LKStatusBadge: View {
    public enum Status: Equatable {
        case connected
        case connecting
        case offline
        case problem
    }

    private let status: Status
    private let label: String?

    public init(_ status: Status, label: String? = nil) {
        self.status = status
        self.label = label
    }

    private var color: Color {
        switch status {
        case .connected: return LK.Palette.success
        case .connecting: return LK.Palette.accent
        case .offline: return .secondary
        case .problem: return LK.Palette.warning
        }
    }

    private var defaultLabel: String {
        switch status {
        case .connected: return "Connected"
        case .connecting: return "Connecting"
        case .offline: return "Offline"
        case .problem: return "Problem"
        }
    }

    public var body: some View {
        HStack(spacing: LK.Spacing.xs + LK.Spacing.xxs) {
            if status == .connecting {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Circle()
                    .fill(color)
                    .frame(width: LK.Size.statusDot, height: LK.Size.statusDot)
            }
            Text(label ?? defaultLabel)
                .font(LK.Typography.captionStrong)
        }
        .padding(.horizontal, LK.Spacing.md)
        .padding(.vertical, LK.Spacing.xs + LK.Spacing.xxs)
        .glassEffect(LK.Glass.bar, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}
