import SwiftUI
import WebKit

/// Previews in artifact cards (docs/artifacts.md, "Previews"): web pages, images, diagrams and
/// components are drawn once, out of sight, and kept as a small picture per version; code,
/// documents and text show their first lines (sent with the card).
#if canImport(UIKit)
import UIKit

@MainActor
final class ArtifactPreviews: NSObject, WKNavigationDelegate {
    static let shared = ArtifactPreviews()
    /// The card's preview area is 300 × 140; a phone-width page drawn at that shape.
    static let size = CGSize(width: 390, height: 182)

    private var memory: [String: UIImage] = [:]
    private var running: [String: Task<UIImage?, Never>] = [:]
    private var busy = false
    private var loaded: CheckedContinuation<Void, Never>?
    private lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: CGRect(origin: CGPoint(x: -4000, y: 0), size: Self.size), configuration: configuration)
        view.navigationDelegate = self
        view.isUserInteractionEnabled = false
        // Drawn from the very top: no room left for the status bar (pictures began with a blank strip).
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.scrollView.contentInset = .zero
        return view
    }()

    private var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lekora/previews", isDirectory: true)
    }

    func image(for card: ArtifactCard, gateway: GatewayClient, profileId: String) async -> UIImage? {
        let key = "p2-\(gateway.savedHost?.instanceId ?? "x")-\(card.artifact_id)-v\(card.version)"
        if let image = memory[key] { return image }
        let file = folder.appendingPathComponent(key + ".png")
        if let data = try? Data(contentsOf: file), let image = UIImage(data: data) {
            memory[key] = image
            return image
        }
        if let task = running[key] { return await task.value }
        let task = Task { await self.draw(card, gateway: gateway, profileId: profileId, to: file) }
        running[key] = task
        let image = await task.value
        running[key] = nil
        if let image { memory[key] = image }
        return image
    }

    /// One at a time, in a web view kept out of sight (it must be in a window to draw).
    private func draw(_ card: ArtifactCard, gateway: GatewayClient, profileId: String, to file: URL) async -> UIImage? {
        while busy { try? await Task.sleep(nanoseconds: 120_000_000) }
        busy = true
        defer { busy = false }
        guard let detail = try? await gateway.artifact(card.artifact_id, version: card.version, in: profileId) else { return nil }
        if webView.window == nil,
           let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.windows.first }).first {
            window.insertSubview(webView, at: 0)
        }
        let html = ArtifactRendering.html(kind: detail.kind, content: detail.content, language: detail.language,
                                          thumbnail: true)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            loaded = done
            webView.loadHTMLString(html, baseURL: URL(string: "https://\(card.artifact_id).artifact.lekora.invalid/"))
            // A page that never finishes loading still gets drawn.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                self?.finishLoading()
            }
        }
        // Scripts, diagrams and components draw after the page loads: wait until they have
        // (a diagram's drawing, a component's first screen), at most 15 s.
        let ready: String
        switch detail.kind {
        case "mermaid": ready = "!!document.querySelector('.mermaid svg')"
        case "react": ready = "(document.getElementById('root')||{}).childElementCount > 0 || !!(document.getElementById('lekora-error')||{}).textContent"
        default: ready = "document.readyState === 'complete'"
        }
        for _ in 0..<50 {
            if (try? await webView.evaluateJavaScript(ready)) as? Bool == true { break }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        try? await Task.sleep(nanoseconds: 500_000_000)  // fonts, the last frame
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(origin: .zero, size: Self.size)
        configuration.snapshotWidth = NSNumber(value: Double(Self.size.width))
        guard let image = try? await webView.takeSnapshot(configuration: configuration) else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? image.pngData()?.write(to: file)
        return image
    }

    private func finishLoading() {
        loaded?.resume()
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finishLoading() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finishLoading() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishLoading()
    }
}

/// The drawn preview, loaded when the card appears.
struct ArtifactPreviewImage: View {
    let card: ArtifactCard
    let load: () async -> UIImage?
    @State private var image: UIImage?
    @State private var tried = false

    var body: some View {
        // The picture fills the area from the top and is trimmed to it (never under the title).
        Color(uiColor: .secondarySystemBackground)
            .overlay(alignment: .top) {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                } else if !tried {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Image(systemName: ArtifactRendering.symbol(card.kind)).font(.title).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .clipped()
        .task(id: "\(card.artifact_id)-\(card.version)") {
            let got = await load()
            withAnimation(.easeOut(duration: 0.2)) { image = got }
            tried = true
        }
    }
}
#endif

/// The first lines of code, a document, a diagram or text, coloured like the viewer.
struct ArtifactExcerpt: View {
    let card: ArtifactCard
    let excerpt: String

    private var language: String? {
        switch card.kind {
        case "code": return card.language
        case "markdown": return "markdown"
        default: return "text"
        }
    }

    var body: some View {
        Text(Self.coloured(excerpt, language: language))
            .font(.system(size: 10.5, design: .monospaced))
            .lineLimit(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(10)
            .background(LK.Surface.inset)
            .clipped()
    }

    static func coloured(_ text: String, language: String?) -> AttributedString {
        var out = AttributedString()
        for segment in CodeHighlighter.segments(text, language: language) {
            var piece = AttributedString(segment.text)
            switch segment.kind {
            case .keyword, .tag: piece.foregroundColor = Color(red: 0.68, green: 0.24, blue: 0.64)
            case .string: piece.foregroundColor = Color(red: 0.85, green: 0.25, blue: 0.2)
            case .number: piece.foregroundColor = Color(red: 0.25, green: 0.35, blue: 0.85)
            case .comment, .meta: piece.foregroundColor = .secondary
            case .type, .function, .key: piece.foregroundColor = Color(red: 0.15, green: 0.55, blue: 0.6)
            case .added: piece.foregroundColor = .green
            case .removed: piece.foregroundColor = .red
            case .variable, .attribute, .hunk: piece.foregroundColor = .orange
            case .plain: piece.foregroundColor = .primary
            }
            out += piece
        }
        return out
    }
}
