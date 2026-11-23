import SwiftUI
import AuthenticationServices
import WebKit

// MCP servers (docs/mcp.md): one page for every agent's MCP servers (owner, 2026-11-22). Hermes keeps
// them per agent; this shows each server once with the agents that have it.

struct McpView: View {
    @ObservedObject var gateway: GatewayClient

    @State private var servers: [McpServer] = []
    @State private var loaded = false
    @State private var failure: String?
    @State private var adding: AddFrom?

    enum AddFrom: String, Identifiable {
        case catalog, registry, custom
        var id: String { rawValue }
    }

    private let sections: [(String, String)] = [("catalog", "Hermes Catalog"), ("registry", "Public Registry"),
                                                ("custom", "Added by You"), ("plugin", "From Plugins")]

    var body: some View {
        List {
            if let failure {
                Section { Text(failure).foregroundStyle(LK.Palette.danger) }
            }
            if !loaded && failure == nil {
                Section { HStack { ProgressView(); Text("Asking Hermes…").foregroundStyle(.secondary) } }
            } else if loaded && servers.isEmpty && failure == nil {
                Section {
                    Text("No MCP servers yet. Tap + to add one from Hermes' catalog, the public registry, or your own.")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(sections, id: \.0) { key, title in
                let inSection = servers.filter { $0.source == key }
                if !inSection.isEmpty {
                    Section(title) {
                        ForEach(inSection) { server in
                            NavigationLink {
                                McpDetailView(gateway: gateway, name: server.name) { Task { await load() } }
                            } label: {
                                row(server)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("MCP Servers")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Hermes Catalog", systemImage: "checkmark.seal") { adding = .catalog }
                    Button("Public Registry", systemImage: "globe") { adding = .registry }
                    Button("Add Your Own", systemImage: "square.and.pencil") { adding = .custom }
                } label: {
                    Label("Add Server", systemImage: "plus")
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $adding, onDismiss: { Task { await load() } }) { from in
            switch from {
            case .catalog: McpCatalogView(gateway: gateway)
            case .registry: McpRegistryView(gateway: gateway)
            case .custom: NavigationStack { McpCustomView(gateway: gateway) }
            }
        }
    }

    private func row(_ server: McpServer) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: LK.Spacing.sm) {
                Text(server.name)
                if server.source == "registry" { LKNotVettedBadge() }
                if server.agents.contains(where: { $0.signed_in == false }) {
                    Label("Sign in needed", systemImage: "person.badge.key")
                        .font(LK.Typography.caption).foregroundStyle(LK.Palette.warning)
                }
            }
            if !server.description.isEmpty {
                Text(server.description).font(LK.Typography.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            LKMcpAgents(gateway: gateway, agents: server.agents)
        }
    }

    private func load() async {
        do {
            servers = try await gateway.mcpServers()
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
        loaded = true
    }
}

/// The public registry isn't checked by Nous (owner, 2026-11-22: show it clearly).
struct LKNotVettedBadge: View {
    var body: some View {
        Text("Not vetted")
            .font(LK.Typography.caption.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(LK.Palette.warning)
            .background(LK.Palette.warning.opacity(0.14), in: Capsule())
            .accessibilityLabel("Not vetted: from the public registry")
    }
}

/// The agents that have a server: their bots, faded where it's off.
struct LKMcpAgents: View {
    @ObservedObject var gateway: GatewayClient
    let agents: [McpServer.Agent]

    var body: some View {
        let count = gateway.profiles.count
        HStack(spacing: 4) {
            ForEach(agents.prefix(8), id: \.profile_id) { agent in
                LKAgentAvatar(id: agent.profile_id, palette: gateway.avatarPalettes[agent.profile_id], size: 18)
                    .opacity(agent.enabled ? 1 : 0.35)
            }
            Text(agents.count == count && count > 1 ? "All agents" : agents.map { gateway.agentName($0.profile_id) }.joined(separator: ", "))
                .font(LK.Typography.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Agents: " + agents.map { gateway.agentName($0.profile_id) + ($0.enabled ? "" : " (off)") }.joined(separator: ", "))
    }
}

// MARK: - One server

struct McpDetailView: View {
    @ObservedObject var gateway: GatewayClient
    let name: String
    var changed: () -> Void = {}

    @State private var server: McpServer?
    @State private var failure: String?
    @State private var busy: Set<String> = []
    @State private var removing: String?
    @State private var test: McpTestResult?
    @State private var testing = false

    var body: some View {
        List {
            if let failure {
                Section { Text(failure).foregroundStyle(LK.Palette.danger) }
            }
            if let server {
                Section {
                    if !server.description.isEmpty { Text(server.description) }
                    LabeledContent("From", value: LKMcpText.source(server.source))
                    if let url = server.url { LabeledContent("Address") { Text(url).textSelection(.enabled).lineLimit(2) } }
                    if let command = server.command {
                        LabeledContent("Runs") { Text(command).font(LK.Typography.code).textSelection(.enabled).lineLimit(3) }
                    }
                    if server.source == "registry" {
                        Text("From the public registry. Nous hasn't checked it; only use servers you trust.")
                            .font(LK.Typography.footnote).foregroundStyle(LK.Palette.warning)
                    }
                }
                Section {
                    ForEach(gateway.profiles) { profile in
                        agentRow(server, profile, server.agents.first { $0.profile_id == profile.profile_id })
                    }
                } header: {
                    Text("Agents")
                } footer: {
                    Text("Adding it to another agent shares its keys and sign-in on your Hermes instance. Changes reach open chats on their next message.")
                }
                Section("Test") {
                    Button {
                        runTest(server)
                    } label: {
                        if testing { HStack { ProgressView(); Text("Asking the server…") } } else { Text("Test Connection") }
                    }
                    .disabled(testing || server.agents.isEmpty)
                    if let test {
                        if test.ok {
                            Label("Works: \(LKMcpText.tools(test.tools?.count ?? 0))", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(LK.Palette.success)
                            ForEach(test.tools ?? [], id: \.self) { tool in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tool.name).font(LK.Typography.code)
                                    if !tool.description.isEmpty {
                                        Text(tool.description).font(LK.Typography.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        } else {
                            Label(test.sign_in == true ? "Needs a sign-in" : LKMcpText.failure(test),
                                  systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(LK.Palette.warning)
                        }
                    }
                }
            } else if failure == nil {
                ProgressView()
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Remove \(name) from \(removing.map(gateway.agentName) ?? "")?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) { if let removing { remove(from: removing) } }
        } message: {
            Text("Its settings are backed up on the Hermes instance first.")
        }
        .task { await load() }
    }

    @ViewBuilder
    private func agentRow(_ server: McpServer, _ profile: ProfileData, _ agent: McpServer.Agent?) -> some View {
        let id = profile.profile_id
        HStack(spacing: LK.Spacing.md) {
            LKAgentAvatar(id: id, palette: gateway.avatarPalettes[id], size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                Text(agent.map { a in a.signed_in == false ? "Not signed in" : "Tools: \(a.tools)" } ?? "Doesn't have it")
                    .font(LK.Typography.caption).foregroundStyle(agent?.signed_in == false ? LK.Palette.warning : .secondary)
            }
            Spacer()
            if busy.contains(id) {
                ProgressView()
            } else if let agent {
                if agent.signed_in == false {
                    McpSignInButton(gateway: gateway, name: server.name, profileId: id) { result in
                        if result.status != "approved" { failure = result.error ?? "The sign-in didn't finish" }
                        Task { await load(); changed() }
                    }
                }
                Toggle(profile.name, isOn: Binding(get: { agent.enabled }, set: { toggle(id, $0) }))
                    .labelsHidden()
                    .disabled(server.source == "plugin")
            } else {
                Button("Add") { add(server, to: id) }
                    .buttonStyle(.bordered)
                    .disabled(server.agents.isEmpty || server.source == "plugin")
            }
        }
        .swipeActions {
            if agent != nil, server.source != "plugin" {
                Button("Remove", role: .destructive) { removing = id }
            }
        }
    }

    private func load() async {
        do {
            server = try await gateway.mcpServers().first { $0.name == name }
            failure = server == nil ? "No agent has this server any more." : nil
        } catch {
            failure = error.localizedDescription
        }
    }

    private func run(_ id: String, _ work: @escaping () async throws -> Void) {
        busy.insert(id)
        Task {
            defer { busy.remove(id) }
            do {
                try await work()
                await load()
                changed()
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    private func toggle(_ id: String, _ on: Bool) {
        run(id) { try await gateway.setMcpServer(name, enabled: on, for: id) }
    }

    private func add(_ server: McpServer, to id: String) {
        guard let from = server.agents.first(where: { $0.signed_in != false })?.profile_id ?? server.agents.first?.profile_id else { return }
        run(id) {
            let result = try await gateway.copyMcpServer(name, from: from, to: [id])
            if let failed = result.failed.first { throw McpFailure(reason: failed.reason) }
        }
    }

    private func remove(from id: String) {
        run(id) { try await gateway.removeMcpServer(name, for: id) }
    }

    private func runTest(_ server: McpServer) {
        guard let agent = server.agents.first(where: \.enabled) ?? server.agents.first else { return }
        testing = true
        test = nil
        Task {
            defer { testing = false }
            do {
                test = try await gateway.testMcpServer(name, for: agent.profile_id)
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

struct McpFailure: LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
}

enum LKMcpText {
    static func tools(_ count: Int) -> String { count == 1 ? "1 tool" : "\(count) tools" }

    static func source(_ source: String) -> String {
        switch source {
        case "catalog": return "Hermes Catalog (vetted by Nous)"
        case "registry": return "Public Registry (not vetted)"
        case "plugin": return "A Hermes plugin"
        default: return "Added by you"
        }
    }

    static func failure(_ test: McpTestResult) -> String {
        switch test.failure {
        case "server_start_failed": return "It couldn't start on the Hermes machine"
        case "config_invalid": return "Its address isn't valid"
        case "missing_credentials": return "A key it needs is missing"
        default: return test.error.map { "It didn't answer: \($0)" } ?? "It didn't answer"
        }
    }
}

// MARK: - Signing in (OAuth), on the phone

/// Signs an agent in to a server: the system sign-in sheet, returning to lekora://mcp-oauth; if the
/// service refuses that address, an in-app browser that catches its return to 127.0.0.1 instead.
/// Hermes checks the result and keeps the sign-in on the instance (docs/mcp.md).
struct McpSignInButton: View {
    @ObservedObject var gateway: GatewayClient
    let name: String
    let profileId: String
    var shareWith: [String] = []
    var title = "Sign In"
    let done: (McpSignIn) -> Void

    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var working = false
    @State private var loopback: LoopbackSignIn?

    static let appReturn = "lekora://mcp-oauth"
    static let loopbackReturn = "http://127.0.0.1:53682/callback"

    var body: some View {
        Button {
            Task { await signIn() }
        } label: {
            if working { ProgressView().accessibilityLabel("Signing in") } else { Text(title) }
        }
        .buttonStyle(.borderedProminent)
        .disabled(working)
        .sheet(item: $loopback) { pending in
            NavigationStack {
                LoopbackSignInView(url: pending.url) { callback in
                    loopback = nil
                    Task { await finish(pending.flowId, callback) }
                }
                .navigationTitle("Sign In")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            loopback = nil
                            Task { await gateway.cancelMcpSignIn(pending.flowId) }
                            working = false
                        }
                    }
                }
            }
        }
    }

    private func signIn() async {
        working = true
        do {
            var started = try await gateway.startMcpSignIn(name, for: profileId, redirect: Self.appReturn, shareWith: shareWith)
            if started.status == "approved" { return finished(started) }
            if started.status == "error" || started.authorization_url == nil {
                // Some services only accept a return to this machine's own address.
                started = try await gateway.startMcpSignIn(name, for: profileId, redirect: Self.loopbackReturn, shareWith: shareWith)
                if let address = started.authorization_url.flatMap(URL.init(string:)), let flowId = started.flow_id {
                    loopback = LoopbackSignIn(flowId: flowId, url: address)
                    return
                }
                return finished(started)
            }
            guard let address = started.authorization_url.flatMap(URL.init(string:)), let flowId = started.flow_id else {
                return finished(started)
            }
            do {
                let callback = try await webAuthenticationSession.authenticate(using: address, callbackURLScheme: "lekora",
                                                                               preferredBrowserSession: .shared)
                await finish(flowId, callback)
            } catch {
                await gateway.cancelMcpSignIn(flowId)
                working = false
            }
        } catch {
            finished(McpSignIn(flow_id: nil, status: "error", authorization_url: nil, error: error.localizedDescription, tools: nil))
        }
    }

    private func finish(_ flowId: String, _ callback: URL) async {
        do {
            finished(try await gateway.finishMcpSignIn(flowId, callback: callback))
        } catch {
            finished(McpSignIn(flow_id: flowId, status: "error", authorization_url: nil, error: error.localizedDescription, tools: nil))
        }
    }

    private func finished(_ result: McpSignIn) {
        working = false
        done(result)
    }
}

struct LoopbackSignIn: Identifiable {
    let flowId: String
    let url: URL
    var id: String { flowId }
}

/// An in-app browser for services that only return to 127.0.0.1: that return is caught here, never loaded.
struct LoopbackSignInView: UIViewRepresentable {
    let url: URL
    let returned: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(returned: returned) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let returned: (URL) -> Void
        private var done = false
        init(returned: @escaping (URL) -> Void) { self.returned = returned }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url, url.host == "127.0.0.1", url.path.hasPrefix("/callback") {
                decisionHandler(.cancel)
                if !done {
                    done = true
                    returned(url)
                }
                return
            }
            decisionHandler(.allow)
        }
    }
}

// MARK: - Adding

/// Which agents, any keys it needs, then add; then sign in if it needs an account.
struct McpAddView: View {
    @ObservedObject var gateway: GatewayClient
    let title: String
    let description: String
    let needs: [McpNeed]
    var vetted = true
    /// Closes the whole Add sheet (after adding).
    var finish: (() -> Void)?
    var note: String?
    /// The request, for the chosen agents and the values typed in.
    let request: (_ to: [String], _ values: [String: String]) -> McpAddRequest
    var added: () -> Void = {}

    @State private var chosen: Set<String> = []
    @State private var values: [String: String] = [:]
    @State private var adding = false
    @State private var result: McpChangeResult?
    @State private var failure: String?
    @State private var signedIn = false

    private var missing: Bool {
        needs.contains { $0.required && ($0.default ?? "").isEmpty && (values[$0.name] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        Form {
            Section {
                if !description.isEmpty { Text(description) }
                if !vetted {
                    Label("From the public registry: Nous hasn't checked it. Only add servers you trust.",
                          systemImage: "exclamationmark.shield")
                        .font(LK.Typography.footnote).foregroundStyle(LK.Palette.warning)
                }
                if let note { Text(note).font(LK.Typography.footnote).foregroundStyle(.secondary) }
            }
            if !needs.isEmpty {
                Section {
                    ForEach(needs, id: \.name) { need in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(need.prompt + (need.required ? "" : " (optional)")).font(LK.Typography.caption).foregroundStyle(.secondary)
                            let binding = Binding(get: { values[need.name] ?? "" }, set: { values[need.name] = $0 })
                            if need.secret {
                                SecureField(need.name, text: binding)
                            } else {
                                TextField(need.default ?? need.name, text: binding)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                            }
                        }
                    }
                } header: {
                    Text("Settings")
                } footer: {
                    if needs.contains(where: \.secret) {
                        Text("Keys are saved by Hermes on your Hermes instance, never on this phone, and aren't shown again.")
                    }
                }
            }
            if result == nil {
                Section("Add For") {
                    LKAgentPicker(gateway: gateway, chosen: $chosen)
                }
            }
            if let failure {
                Section { Text(failure).foregroundStyle(LK.Palette.danger) }
            }
            if let result {
                outcome(result)
            } else {
                Section {
                    Button {
                        add()
                    } label: {
                        if adding { HStack { ProgressView(); Text("Adding and testing…") } }
                        else { Text(chosen.count == 1 ? "Add for 1 Agent" : "Add for \(chosen.count) Agents") }
                    }
                    .disabled(adding || chosen.isEmpty || missing)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(result != nil)
        .toolbar {
            if result != nil, let finish {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: finish) }
            }
        }
        .onAppear {
            if chosen.isEmpty { chosen = Set(gateway.profiles.map(\.profile_id)) }
            for need in needs where values[need.name] == nil { values[need.name] = need.default ?? "" }
        }
    }

    @ViewBuilder
    private func outcome(_ result: McpChangeResult) -> some View {
        Section {
            if result.added.isEmpty && result.failed.isEmpty {
                Text("Every agent you picked has it already.")
            }
            if !result.added.isEmpty {
                Label("Added for " + result.added.map(gateway.agentName).joined(separator: ", "), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(LK.Palette.success)
            }
            ForEach(result.failed, id: \.profile_id) { failed in
                Label("\(gateway.agentName(failed.profile_id)): \(failed.reason)", systemImage: "xmark.octagon")
                    .foregroundStyle(LK.Palette.danger)
            }
            if let test = result.test {
                if test.ok {
                    Text("It works: \(LKMcpText.tools(test.tools?.count ?? 0)).").foregroundStyle(.secondary)
                } else if test.sign_in == true && !signedIn, let first = result.added.first {
                    VStack(alignment: .leading, spacing: LK.Spacing.sm) {
                        Text("It needs you to sign in to your account. You sign in once; every agent you picked uses it.")
                            .font(LK.Typography.footnote)
                        McpSignInButton(gateway: gateway, name: result.name, profileId: first,
                                        shareWith: Array(result.added.dropFirst()), title: "Sign In") { signIn in
                            if signIn.status == "approved" {
                                signedIn = true
                                failure = nil
                            } else {
                                failure = signIn.error ?? "The sign-in didn't finish. You can sign in later from the server's page."
                            }
                        }
                    }
                } else if signedIn {
                    Label("Signed in", systemImage: "checkmark.seal.fill").foregroundStyle(LK.Palette.success)
                } else if test.sign_in != true {
                    Text(LKMcpText.failure(test) + ". It's added; check its settings, then Test on its page.")
                        .font(LK.Typography.footnote).foregroundStyle(LK.Palette.warning)
                }
            }
            Text("Open chats get its tools on their next message.").font(LK.Typography.footnote).foregroundStyle(.secondary)
        }
    }

    private func add() {
        adding = true
        failure = nil
        let to = gateway.profiles.map(\.profile_id).filter { chosen.contains($0) }
        let given = values.filter { !$0.value.isEmpty }
        Task {
            defer { adding = false }
            do {
                result = try await gateway.addMcpServer(request(to, given))
                added()
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

/// Hermes' own catalog: servers Nous has checked.
struct McpCatalogView: View {
    @ObservedObject var gateway: GatewayClient
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [McpCatalogEntry] = []
    @State private var query = ""
    @State private var failure: String?
    @State private var loaded = false

    private var shown: [McpCatalogEntry] {
        let words = query.lowercased().split(separator: " ")
        return entries.filter { e in words.allSatisfy { "\(e.name) \(e.description)".lowercased().contains($0) } }
    }

    var body: some View {
        NavigationStack {
            List {
                if let failure { Text(failure).foregroundStyle(LK.Palette.danger) }
                if !loaded && failure == nil { ProgressView() }
                ForEach(shown) { entry in
                    NavigationLink {
                        McpAddView(gateway: gateway, title: entry.name, description: entry.description, needs: entry.needs,
                                   finish: { dismiss() }, note: entry.preregistered == true ? "This one signs in with a client set up on the Hermes machine: install it there with “hermes mcp install \(entry.name)”." : (entry.auth == "oauth" ? "Needs a sign-in to your account after adding." : nil)) { to, values in
                            McpAddRequest(source: "catalog", name: entry.name, to: to, values: values)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(entry.name)
                                Spacer()
                                if !entry.installed_for.isEmpty {
                                    Text(entry.installed_for.count == gateway.profiles.count ? "Added" : "\(entry.installed_for.count) agents")
                                        .font(LK.Typography.caption).foregroundStyle(.secondary)
                                }
                            }
                            Text(entry.description).font(LK.Typography.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search Hermes' catalog")
            .navigationTitle("Hermes Catalog")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task {
                do { entries = try await gateway.mcpCatalog() } catch { failure = error.localizedDescription }
                loaded = true
            }
        }
    }
}

/// The official public MCP registry: thousands of servers, none checked by Nous.
struct McpRegistryView: View {
    @ObservedObject var gateway: GatewayClient
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [McpRegistryResult] = []
    @State private var searching = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("The public registry isn't checked by Nous. Only add servers from people you trust.",
                          systemImage: "exclamationmark.shield")
                        .font(LK.Typography.footnote).foregroundStyle(LK.Palette.warning)
                }
                if let failure { Text(failure).foregroundStyle(LK.Palette.danger) }
                if searching { HStack { ProgressView(); Text("Searching the registry…").foregroundStyle(.secondary) } }
                ForEach(results) { result in
                    if result.runnable {
                        NavigationLink {
                            McpAddView(gateway: gateway, title: result.title, description: result.description, needs: result.needs,
                                       vetted: false, finish: { dismiss() }, note: "\(result.id) · v\(result.version)") { to, values in
                                McpAddRequest(source: "registry", name: result.name, id: result.id, to: to, values: values)
                            }
                        } label: {
                            resultRow(result)
                        }
                    } else {
                        resultRow(result)
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search the public registry")
            .onSubmit(of: .search) { search() }
            .navigationTitle("Public Registry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func resultRow(_ result: McpRegistryResult) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(result.title)
                LKNotVettedBadge()
            }
            Text(result.id).font(Font.caption2).foregroundStyle(.tertiary)
            if !result.description.isEmpty {
                Text(result.description).font(LK.Typography.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if let reason = result.reason {
                Text("Can't run here: \(reason)").font(LK.Typography.caption).foregroundStyle(LK.Palette.warning)
            }
        }
    }

    private func search() {
        let words = query.trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty else { return }
        searching = true
        failure = nil
        Task {
            defer { searching = false }
            do { results = try await gateway.searchMcpRegistry(words) } catch { failure = error.localizedDescription }
        }
    }
}

/// Your own server: an address, or a command Hermes runs.
struct McpCustomView: View {
    @ObservedObject var gateway: GatewayClient
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var byAddress = true
    @State private var url = ""
    @State private var token = ""
    @State private var accountSignIn = false
    @State private var command = ""
    @State private var arguments = ""
    @State private var settings = ""

    private var cleanName: String { name.trimmingCharacters(in: .whitespaces).lowercased() }

    var body: some View {
        Form {
            Section {
                TextField("Name (e.g. my-tools)", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled()
                Picker("Connect by", selection: $byAddress) {
                    Text("Address").tag(true)
                    Text("Command").tag(false)
                }
                .pickerStyle(.segmented)
            }
            if byAddress {
                Section {
                    TextField("https://…/mcp", text: $url).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Access token (optional)", text: $token)
                    Toggle("Signs in to an account", isOn: $accountSignIn).disabled(!token.isEmpty)
                } footer: {
                    Text("A token is saved by Hermes on your Hermes instance and sent as “Bearer …”.")
                }
            } else {
                Section {
                    TextField("Command (e.g. npx)", text: $command).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Arguments (e.g. -y my-mcp-server)", text: $arguments).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Settings, one per line: NAME=value", text: $settings, axis: .vertical)
                        .lineLimit(2...6).font(LK.Typography.code).textInputAutocapitalization(.never).autocorrectionDisabled()
                } footer: {
                    Text("It runs on the Hermes machine. Settings are saved by Hermes in each agent's .env. Hermes' safety check refuses risky commands.")
                }
            }
            Section {
                NavigationLink("Next") {
                    McpAddView(gateway: gateway, title: cleanName, description: "", needs: [], finish: { dismiss() }) { to, _ in request(to) }
                }
                .disabled(cleanName.isEmpty || (byAddress ? url.isEmpty : command.isEmpty))
            }
        }
        .navigationTitle("Add Your Own")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }

    private func request(_ to: [String]) -> McpAddRequest {
        if byAddress {
            return McpAddRequest(source: "custom", name: cleanName, to: to, url: url.trimmingCharacters(in: .whitespaces),
                                 bearer: token.isEmpty ? nil : token, oauth: token.isEmpty && accountSignIn ? true : nil)
        }
        var env: [String: String] = [:]
        for line in settings.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, !parts[0].isEmpty { env[parts[0]] = parts[1] }
        }
        return McpAddRequest(source: "custom", name: cleanName, to: to, command: command.trimmingCharacters(in: .whitespaces),
                             args: arguments.split(separator: " ").map(String.init), env: env.isEmpty ? nil : env)
    }
}
