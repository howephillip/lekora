import SwiftUI

/// Editing code artifacts (docs/artifacts.md, "Code"): monospaced, coloured as you type
/// (CodeHighlighter), no autocorrect, smart quotes or capitals, and a row of keys code needs
/// (tab, brackets, quotes, operators) above the keyboard.
#if os(iOS)
import UIKit

struct CodeEditorView: UIViewRepresentable {
    @Binding var text: String
    let language: String?
    var fontSize: CGFloat = 14

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.keyboardType = .asciiCapable
        view.alwaysBounceVertical = true
        view.keyboardDismissMode = .interactive
        view.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 40, right: 8)
        view.backgroundColor = .systemBackground
        view.inputAccessoryView = context.coordinator.keysBar(for: view)
        view.text = text
        context.coordinator.highlight(view, now: true)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text {
            view.text = text
            context.coordinator.highlight(view, now: true)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CodeEditorView
        private var pending: Task<Void, Never>?
        private weak var view: UITextView?

        init(_ parent: CodeEditorView) { self.parent = parent }

        private var font: UIFont { .monospacedSystemFont(ofSize: parent.fontSize, weight: .regular) }

        func textViewDidChange(_ view: UITextView) {
            parent.text = view.text
            highlight(view, now: false)
        }

        /// Colours the whole text; a short wait while typing in big files, so keys never lag.
        func highlight(_ view: UITextView, now: Bool) {
            pending?.cancel()
            let delay: UInt64 = now ? 0 : (view.text.utf16.count > 60_000 ? 400_000_000 : 60_000_000)
            pending = Task { [weak self, weak view] in
                if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
                guard !Task.isCancelled, let self, let view else { return }
                self.apply(to: view)
            }
            if now { apply(to: view) }
        }

        private func apply(to view: UITextView) {
            let text = view.text ?? ""
            let selected = view.selectedRange
            let storage = view.textStorage
            storage.beginEditing()
            let whole = NSRange(location: 0, length: (text as NSString).length)
            storage.setAttributes([.font: font, .foregroundColor: UIColor.label], range: whole)
            var location = 0
            for segment in CodeHighlighter.segments(text, language: parent.language) {
                let length = (segment.text as NSString).length
                if segment.kind != .plain, location + length <= whole.length {
                    storage.addAttributes(Self.attributes(segment.kind, font: font), range: NSRange(location: location, length: length))
                }
                location += length
            }
            storage.endEditing()
            view.typingAttributes = [.font: font, .foregroundColor: UIColor.label]
            if selected.location + selected.length <= whole.length { view.selectedRange = selected }
        }

        static func attributes(_ kind: CodeHighlighter.Kind, font: UIFont) -> [NSAttributedString.Key: Any] {
            func color(_ light: Int, _ dark: Int) -> UIColor {
                UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) }
            }
            let bold = UIFont.monospacedSystemFont(ofSize: font.pointSize, weight: .semibold)
            switch kind {
            case .keyword: return [.foregroundColor: color(0x9b2393, 0xff7ab2), .font: bold]
            case .type: return [.foregroundColor: color(0x0b4f79, 0x6bdfff)]
            case .function: return [.foregroundColor: color(0x326d74, 0x67b7a4)]
            case .string: return [.foregroundColor: color(0xc41a16, 0xff8170)]
            case .number: return [.foregroundColor: color(0x1c00cf, 0xd9c97c)]
            case .comment: return [.foregroundColor: color(0x5d6c79, 0x7f8c98)]
            case .key: return [.foregroundColor: color(0x0b4f79, 0x6bdfff), .font: bold]
            case .variable: return [.foregroundColor: color(0x643820, 0xb281eb)]
            case .tag: return [.foregroundColor: color(0x9b2393, 0xff7ab2)]
            case .attribute: return [.foregroundColor: color(0x815f03, 0xd9a15c)]
            case .added: return [.foregroundColor: color(0x1a7f37, 0x7ee787), .backgroundColor: UIColor.systemGreen.withAlphaComponent(0.15)]
            case .removed: return [.foregroundColor: color(0xcf222e, 0xffa198), .backgroundColor: UIColor.systemRed.withAlphaComponent(0.15)]
            case .hunk: return [.foregroundColor: color(0x6f42c1, 0xd2a8ff), .font: bold]
            case .meta: return [.foregroundColor: UIColor.secondaryLabel, .font: bold]
            case .plain: return [:]
            }
        }

        // MARK: - Keys above the keyboard

        private static let keys = ["⇥", "{", "}", "(", ")", "[", "]", "<", ">", "=", ";", ":", "\"", "'", "`", "/", "\\", "|", "&", "!", "?", "-", "+", "*", "_", "$", "#", "@", "%", "~"]

        func keysBar(for view: UITextView) -> UIView {
            self.view = view
            let bar = UIInputView(frame: CGRect(x: 0, y: 0, width: 0, height: 44), inputViewStyle: .keyboard)
            let scroll = UIScrollView()
            scroll.showsHorizontalScrollIndicator = false
            scroll.translatesAutoresizingMaskIntoConstraints = false
            let stack = UIStackView()
            stack.axis = .horizontal
            stack.spacing = 6
            stack.translatesAutoresizingMaskIntoConstraints = false
            for key in Self.keys {
                var configuration = UIButton.Configuration.gray()
                configuration.title = key
                configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
                let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
                    self?.insert(key == "⇥" ? "    " : key)
                })
                button.accessibilityLabel = key == "⇥" ? "Tab" : key
                stack.addArrangedSubview(button)
            }
            let done = UIButton(configuration: .borderedProminent(), primaryAction: UIAction { [weak view] _ in
                view?.resignFirstResponder()
            })
            done.setImage(UIImage(systemName: "keyboard.chevron.compact.down"), for: .normal)
            done.accessibilityLabel = "Hide keyboard"
            stack.addArrangedSubview(done)
            scroll.addSubview(stack)
            bar.addSubview(scroll)
            NSLayoutConstraint.activate([
                scroll.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
                scroll.topAnchor.constraint(equalTo: bar.topAnchor),
                scroll.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
                stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
                stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
                stack.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            ])
            return bar
        }

        private func insert(_ text: String) {
            guard let view else { return }
            view.insertText(text)
        }
    }
}

private extension UIColor {
    convenience init(hex: Int) {
        self.init(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}
#else
struct CodeEditorView: View {
    @Binding var text: String
    let language: String?
    var fontSize: CGFloat = 14
    var body: some View {
        TextEditor(text: $text).font(.system(size: fontSize, design: .monospaced))
    }
}
#endif
