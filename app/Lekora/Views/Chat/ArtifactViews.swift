import SwiftUI
import WebKit

// Artifacts (docs/artifacts.md): the card in the chat, the full-screen viewer (versions, edit,
// ask to change, share as file or PDF) and an agent's list.

/// The sealed web view every artifact is shown in. Scripts run and online content loads (the
/// owner's choice), but there's no bridge to the app and nothing is kept between openings;
/// tapped links open in Safari, not over the artifact.
@MainActor
final class ArtifactWebController: NSObject, ObservableObject, WKNavigationDelegate {
    let webView: WKWebView

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        #if os(iOS)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        #endif
    }

    /// Each artifact gets its own made-up origin, so it can't read another one's storage.
    func show(_ html: String, artifactId: String) {
        webView.loadHTMLString(html, baseURL: URL(string: "https://\(artifactId).artifact.lekora.invalid/"))
    }

    func pdf() async throws -> Data {
        try await webView.pdf()
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        if action.navigationType == .linkActivated, let url = action.request.url,
           ["http", "https", "mailto", "tel"].contains(url.scheme?.lowercased() ?? "") {
            #if os(iOS)
            await UIApplication.shared.open(url)
            #endif
            return .cancel
        }
        return .allow
    }
}

#if os(iOS)
struct ArtifactWebView: UIViewRepresentable {
    let controller: ArtifactWebController
    func makeUIView(context: Context) -> WKWebView { controller.webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}

/// The system share sheet for a file made on the spot (the artifact as a file, or its PDF).
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#else
struct ArtifactWebView: NSViewRepresentable {
    let controller: ArtifactWebController
    func makeNSView(context: Context) -> WKWebView { controller.webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#endif

// MARK: - The card in the chat

struct LKArtifactCard: View {
    let artifact: ArtifactCard
    let fromUser: Bool
    let open: () -> Void

    private var subtitle: String {
        let kind = ArtifactRendering.kindName(artifact.kind, language: artifact.language)
        switch artifact.action {
        case "updated": return "\(kind) · Updated to v\(artifact.version)"
        case "edited": return "You edited · v\(artifact.version)"
        default: return artifact.version > 1 ? "\(kind) · v\(artifact.version)" : kind
        }
    }

    var body: some View {
        HStack {
            if fromUser { Spacer(minLength: LK.Size.bubbleSideMargin) }
            Button(action: open) {
                HStack(spacing: LK.Spacing.sm) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(fromUser ? Color.white.opacity(0.2) : LK.Palette.accent.opacity(0.14))
                        Image(systemName: ArtifactRendering.symbol(artifact.kind))
                            .font(.system(size: 20, weight: .medium))
                    }
                    .frame(width: 46, height: 46)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(artifact.title)
                            .font(LK.Typography.subheadline.weight(.semibold))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(subtitle)
                            .font(LK.Typography.caption)
                            .opacity(0.75)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .opacity(0.5)
                }
                .foregroundStyle(fromUser ? LK.Palette.onAccent : .primary)
                .padding(LK.Spacing.sm)
                .frame(maxWidth: 300, alignment: .leading)
                .background(fromUser ? LK.Surface.accent : LK.Surface.inset,
                            in: RoundedRectangle(cornerRadius: LK.Radius.bubble, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(artifact.title), \(subtitle)")
            .accessibilityHint("Opens it")
            if !fromUser { Spacer(minLength: LK.Size.bubbleSideMargin) }
        }
    }
}

/// On your own message: which artifact it's about ("ask to change").
struct LKArtifactChip: View {
    let artifact: ArtifactCard
    let open: () -> Void

    var body: some View {
        HStack {
            Spacer(minLength: LK.Size.bubbleSideMargin)
            Button(action: open) {
                Label(artifact.title, systemImage: ArtifactRendering.symbol(artifact.kind))
                    .font(LK.Typography.caption.weight(.semibold))
                    .lineLimit(1)
                    .padding(.horizontal, LK.Spacing.sm)
                    .padding(.vertical, 4)
                    .background(LK.Surface.inset, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("About \(artifact.title)")
        }
    }
}

// MARK: - The viewer

struct ArtifactViewer: View {
    @ObservedObject var gateway: GatewayClient
    let profileId: String
    let artifactId: String
    let agentName: String

    @Environment(\.dismiss) private var dismiss
    @StateObject private var web = ArtifactWebController()
    @State private var detail: ArtifactDetail?
    @State private var failure: String?
    @State private var notice: String?
    @State private var editing = false
    @State private var asking = false
    @State private var sharing: URL?
    @State private var working = false

    private var isLatest: Bool { detail.map { $0.shown_version == $0.version } ?? true }

    var body: some View {
        NavigationStack {
            ZStack {
                ArtifactWebView(controller: web)
                    .ignoresSafeArea(edges: .bottom)
                    .opacity(detail == nil ? 0 : 1)
                if detail == nil {
                    if let failure {
                        LKNotice(.warning, failure).padding()
                    } else {
                        ProgressView()
                    }
                }
            }
            .safeAreaInset(edge: .top) {
                if let detail, !isLatest {
                    HStack {
                        Text("Version \(detail.shown_version) of \(detail.version)")
                            .font(LK.Typography.footnote)
                        Spacer()
                        Button("Restore This Version") { restore() }
                            .font(LK.Typography.footnote.weight(.semibold))
                            .disabled(working)
                        Button("Latest") { Task { await load(nil) } }
                            .font(LK.Typography.footnote)
                    }
                    .padding(.horizontal, LK.Spacing.lg)
                    .padding(.vertical, LK.Spacing.sm)
                    .background(.bar)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let notice {
                    Text(notice)
                        .font(LK.Typography.footnote)
                        .padding(.horizontal, LK.Spacing.md)
                        .padding(.vertical, LK.Spacing.sm)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, LK.Spacing.md)
                        .transition(.opacity)
                }
            }
            .navigationTitle(detail?.title ?? "Artifact")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbar }
            .sheet(isPresented: $editing) {
                if let detail {
                    ArtifactEditor(detail: detail) { content in
                        try await save(content, note: nil)
                    }
                }
            }
            .sheet(isPresented: $asking) {
                if let detail {
                    AskToChangeSheet(title: detail.title, agentName: agentName) { request in
                        await gateway.sendMessage(request, about: detail.card)
                        dismiss()  // back to the chat, where the agent answers
                    }
                    .presentationDetents([.medium])
                }
            }
            #if os(iOS)
            .sheet(item: Binding(get: { sharing.map(SharedFile.init) }, set: { if $0 == nil { sharing = nil } })) { file in
                ShareSheet(url: file.url).presentationDetents([.medium, .large])
            }
            #endif
            .task { await load(nil) }
            .onChange(of: gateway.artifactVersions[artifactId]) { _, newest in
                // Changed elsewhere (the agent, another phone): show the newest, if that's what's open.
                if let newest, let detail, isLatest, newest > detail.version { Task { await load(nil) } }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Done") { dismiss() }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if let detail {
                Menu {
                    Picker("Version", selection: Binding(get: { detail.shown_version },
                                                         set: { version in Task { await load(version) } })) {
                        ForEach(detail.versions) { version in
                            Text(versionLabel(version)).tag(version.version)
                        }
                    }
                } label: {
                    Label("Versions", systemImage: "clock.arrow.circlepath")
                }
                Menu {
                    Button("Ask \(agentName) to Change…", systemImage: "sparkles") { asking = true }
                    Button("Edit Myself…", systemImage: "pencil") { editing = true }
                        .disabled(!isLatest)
                } label: {
                    Label("Change", systemImage: "pencil.and.outline")
                }
                Menu {
                    Button("Share File", systemImage: "doc") { shareFile(detail) }
                    Button("Share as PDF", systemImage: "doc.richtext") { sharePDF(detail) }
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .disabled(working)
            }
        }
    }

    private func versionLabel(_ version: ArtifactVersionInfo) -> String {
        var parts = ["v\(version.version)", version.author == "user" ? "by you" : "by \(agentName)"]
        if let note = version.note, !note.isEmpty { parts.append(note) }
        if let at = version.created_at.flatMap({ try? Date($0, strategy: .iso8601) }) {
            parts.append(at.formatted(date: .abbreviated, time: .shortened))
        }
        return parts.joined(separator: " · ")
    }

    private func load(_ version: Int?) async {
        do {
            let got = try await gateway.artifact(artifactId, version: version, in: profileId)
            detail = got
            failure = nil
            web.show(ArtifactRendering.html(kind: got.kind, content: got.content, language: got.language),
                     artifactId: got.artifact_id)
        } catch {
            failure = "Couldn't open it: \(error.localizedDescription)"
        }
    }

    private func save(_ content: String, note: String?) async throws {
        guard let detail else { return }
        do {
            _ = try await gateway.saveArtifact(artifactId, content: content, baseVersion: detail.version,
                                               note: note, in: profileId)
            await load(nil)
            show("Saved as version \(self.detail?.version ?? detail.version + 1)")
        } catch let error as HostError where error.code == "ARTIFACT_CHANGED" {
            await load(nil)
            throw error
        }
    }

    private func restore() {
        guard let detail else { return }
        working = true
        Task {
            defer { working = false }
            do {
                let latest = try await gateway.artifact(artifactId, in: profileId)
                _ = try await gateway.saveArtifact(artifactId, content: detail.content, baseVersion: latest.version,
                                                   note: "Restored version \(detail.shown_version)", in: profileId)
                await load(nil)
                show("Restored as version \(self.detail?.version ?? 0)")
            } catch {
                show("Couldn't restore it: \(error.localizedDescription)")
            }
        }
    }

    private func shareFile(_ detail: ArtifactDetail) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            ArtifactRendering.fileName(title: detail.title, kind: detail.kind, language: detail.language))
        do {
            try detail.content.write(to: url, atomically: true, encoding: .utf8)
            sharing = url
        } catch {
            show("Couldn't make the file: \(error.localizedDescription)")
        }
    }

    private func sharePDF(_ detail: ArtifactDetail) {
        working = true
        Task {
            defer { working = false }
            do {
                let data = try await web.pdf()
                let name = ArtifactRendering.fileName(title: detail.title, kind: "text", language: nil)
                    .replacingOccurrences(of: ".txt", with: ".pdf")
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                try data.write(to: url)
                sharing = url
            } catch {
                show("Couldn't make a PDF: \(error.localizedDescription)")
            }
        }
    }

    private func show(_ text: String) {
        withAnimation { notice = text }
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            withAnimation { if notice == text { notice = nil } }
        }
    }
}

private struct SharedFile: Identifiable {
    let url: URL
    var id: String { url.path }
}

/// "Edit Myself": the text or code; Save makes a new version by you.
struct ArtifactEditor: View {
    let detail: ArtifactDetail
    let save: (String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var saving = false
    @State private var failure: String?

    init(detail: ArtifactDetail, save: @escaping (String) async throws -> Void) {
        self.detail = detail
        self.save = save
        _text = State(initialValue: detail.content)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let failure {
                    LKNotice(.warning, failure).padding()
                }
                TextEditor(text: $text)
                    .font(detail.kind == "markdown" || detail.kind == "text"
                          ? LK.Typography.body : .system(.footnote, design: .monospaced))
                    .autocorrectionDisabled(detail.kind != "markdown" && detail.kind != "text")
                    #if os(iOS)
                    .textInputAutocapitalization(detail.kind == "markdown" || detail.kind == "text" ? .sentences : .never)
                    #endif
                    .padding(.horizontal, LK.Spacing.sm)
            }
            .navigationTitle("Edit \(detail.title)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saving = true
                        Task {
                            defer { saving = false }
                            do {
                                try await save(text)
                                dismiss()
                            } catch let error as HostError where error.code == "ARTIFACT_CHANGED" {
                                failure = "\(error.reason) Your text is still here: copy what you need, then edit the latest."
                            } catch {
                                failure = "Couldn't save: \(error.localizedDescription)"
                            }
                        }
                    }
                    .disabled(saving || text == detail.content || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .interactiveDismissDisabled(text != detail.content)
        }
    }
}

/// "Ask to Change": your request goes to the agent as your message, about this artifact.
struct AskToChangeSheet: View {
    let title: String
    let agentName: String
    let send: (String) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var request = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("e.g. Make the chart blue and add a total", text: $request, axis: .vertical)
                        .lineLimit(3...8)
                        .focused($focused)
                } footer: {
                    Text("Sent to \(agentName) as your message, about “\(title)”. The change comes back as a new version.")
                }
            }
            .navigationTitle("Ask to Change")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        let text = request
                        Task {
                            dismiss()
                            await send(text)
                        }
                    }
                    .disabled(request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
    }
}

// MARK: - An agent's list

struct ArtifactsListView: View {
    @ObservedObject var gateway: GatewayClient
    let profileId: String
    let agentName: String
    @State private var artifacts: [ArtifactCard]?
    @State private var failure: String?
    @State private var opened: ArtifactCard?

    var body: some View {
        List {
            if let artifacts {
                if artifacts.isEmpty {
                    Text("Nothing yet. When \(agentName) makes a web page, document or code for you, it's kept here.")
                        .font(LK.Typography.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(artifacts) { artifact in
                    Button { opened = artifact } label: {
                        HStack(spacing: LK.Spacing.md) {
                            Image(systemName: ArtifactRendering.symbol(artifact.kind))
                                .frame(width: 28)
                                .foregroundStyle(LK.Palette.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(artifact.title).foregroundStyle(.primary)
                                Text(rowDetail(artifact))
                                    .font(LK.Typography.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else if let failure {
                LKNotice(.warning, failure)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Artifacts")
        .task { await load() }
        .refreshable { await load() }
        #if os(iOS)
        .fullScreenCover(item: $opened) { artifact in
            ArtifactViewer(gateway: gateway, profileId: profileId, artifactId: artifact.artifact_id, agentName: agentName)
        }
        #endif
    }

    private func rowDetail(_ artifact: ArtifactCard) -> String {
        var parts = [ArtifactRendering.kindName(artifact.kind, language: artifact.language), "v\(artifact.version)"]
        if let at = artifact.updated_at.flatMap({ try? Date($0, strategy: .iso8601) }) {
            parts.append(at.formatted(.relative(presentation: .named)))
        }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        do {
            artifacts = try await gateway.artifacts(for: profileId)
            failure = nil
        } catch {
            failure = "Couldn't load them: \(error.localizedDescription). The Lekora plugin on the Hermes instance may need updating."
        }
    }
}
