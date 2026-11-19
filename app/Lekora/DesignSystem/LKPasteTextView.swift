import SwiftUI
#if canImport(UIKit)
import UIKit
import UniformTypeIdentifiers

/// The message bar's text field, as in Messages: it grows to five lines, and Paste takes photos
/// and files as well as text (SwiftUI's own field only pastes text). Pasted photos and files go to
/// `onPaste`; text is pasted as usual.
struct LKPasteTextView: UIViewRepresentable {
    let placeholder: String
    @Binding var text: String
    var focus: FocusState<Bool>.Binding?
    /// Goes up each time the chat wants the keyboard (after sending, picking a command).
    var focusRequest: Int = 0
    let maxLines: Int
    let onPaste: ([NSItemProvider]) -> Void

    func makeUIView(context: Context) -> PastingTextView {
        let view = PastingTextView()
        context.coordinator.lastRequest = focusRequest
        view.delegate = context.coordinator
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: LK.Spacing.md, left: 0, bottom: LK.Spacing.md, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.placeholder.text = placeholder
        view.onPaste = onPaste
        view.accessibilityLabel = placeholder
        return view
    }

    func updateUIView(_ view: PastingTextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text { view.text = text }
        view.placeholder.text = placeholder
        view.placeholder.isHidden = !text.isEmpty
        view.onPaste = onPaste
        // The chat asks for the keyboard by setting its focus to true (after sending, or picking a
        // command): act on that request only. Never resign from it: SwiftUI puts a focus state that
        // isn't tied to one of its own fields back to false, and resigning then dropped the keyboard
        // while typing (simulator check, 2026-11-18). The keyboard goes away as usual (scrolling).
        if let focus {
            let wanted = focus.wrappedValue
            if wanted, !context.coordinator.lastWanted, !view.isFirstResponder { view.requestFocus() }
            context.coordinator.lastWanted = wanted
        }
        if focusRequest != context.coordinator.lastRequest {
            context.coordinator.lastRequest = focusRequest
            if !view.isFirstResponder { view.requestFocus() }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: PastingTextView, context: Context) -> CGSize? {
        // Fill the width offered (the row is flexible), but measure the height at a real width:
        // measuring at "unlimited" gave a wrong height and the bar covered the commands list above it.
        let offered = proposal.width ?? 240
        let width = offered.isFinite && offered > 0 ? offered : (view.bounds.width > 0 ? view.bounds.width : 240)
        let fitting = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let line = view.font?.lineHeight ?? 22
        let most = line * CGFloat(maxLines) + view.textContainerInset.top + view.textContainerInset.bottom
        let scrolls = fitting.height > most
        if view.isScrollEnabled != scrolls {
            DispatchQueue.main.async { view.isScrollEnabled = scrolls }
        }
        return CGSize(width: offered.isFinite ? width : offered, height: min(fitting.height, most))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: LKPasteTextView
        /// The focus value last seen: only a change to true is a request for the keyboard.
        var lastWanted = false
        var lastRequest = 0
        init(_ parent: LKPasteTextView) { self.parent = parent }

        func textViewDidChange(_ view: UITextView) {
            parent.text = view.text
            (view as? PastingTextView)?.placeholder.isHidden = !view.text.isEmpty
            view.invalidateIntrinsicContentSize()
        }

        func textViewDidBeginEditing(_ view: UITextView) {
            lastWanted = true
            if parent.focus?.wrappedValue == false { parent.focus?.wrappedValue = true }  // e.g. keep the newest message in view
        }

        func textViewDidEndEditing(_ view: UITextView) {
            lastWanted = false
            if parent.focus?.wrappedValue == true { parent.focus?.wrappedValue = false }
        }
    }
}

/// A text view whose Paste also takes photos and files.
final class PastingTextView: UITextView {
    var onPaste: (([NSItemProvider]) -> Void)?
    let placeholder = UILabel()
    private var focusWhenShown = false

    /// The keyboard now, or as soon as the field is on screen.
    func requestFocus() {
        if window != nil {
            DispatchQueue.main.async { [weak self] in _ = self?.becomeFirstResponder() }
        } else {
            focusWhenShown = true
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, focusWhenShown {
            focusWhenShown = false
            DispatchQueue.main.async { [weak self] in _ = self?.becomeFirstResponder() }
        }
    }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        placeholder.font = .preferredFont(forTextStyle: .body)
        placeholder.adjustsFontForContentSizeCategory = true
        placeholder.textColor = .placeholderText
        placeholder.isAccessibilityElement = false
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.leadingAnchor.constraint(equalTo: leadingAnchor),
            placeholder.topAnchor.constraint(equalTo: topAnchor, constant: LK.Spacing.md),
        ])
        // Photos and files dropped or pasted from other apps count too.
        pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: Self.acceptedTypes)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    static let acceptedTypes = [UTType.image.identifier, UTType.movie.identifier, UTType.pdf.identifier,
                                UTType.item.identifier, UTType.plainText.identifier, UTType.url.identifier]

    /// Something on the clipboard that is a photo or file, not just text.
    static func hasAttachment(_ board: UIPasteboard = .general) -> Bool {
        if board.hasImages { return true }
        return board.itemProviders.contains { provider in
            !provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
                && !provider.hasItemConformingToTypeIdentifier(UTType.url.identifier)
                && (provider.hasItemConformingToTypeIdentifier(UTType.data.identifier)
                    || provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))
        }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), Self.hasAttachment() { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        let board = UIPasteboard.general
        if Self.hasAttachment(board) {
            onPaste?(board.itemProviders)
            // Text that came along with the pictures (e.g. a caption) is pasted too.
            if !board.hasImages, let words = board.string, !words.isEmpty,
               !board.itemProviders.contains(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) {
                insertText(words)
            }
            return
        }
        super.paste(sender)
    }

    override func paste(itemProviders: [NSItemProvider]) {
        let attachments = itemProviders.filter {
            !$0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
                && !$0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
        }
        if attachments.isEmpty {
            super.paste(itemProviders: itemProviders)
        } else {
            onPaste?(attachments)
        }
    }
}
#endif

