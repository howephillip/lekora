import SwiftUI

// The model picker's sheet (docs/model-picker.md): every model Hermes can switch to, with
// prices and abilities; OpenRouter's whole tool-capable catalog to browse; and per model,
// the companies hosting it and which of them OpenRouter may use.

/// Where the picker gets details beyond Hermes' own list.
public struct LKModelSource {
    public var catalog: (_ provider: String, _ models: [String]) async throws -> [CatalogModel]
    public var hosts: (_ model: String) async throws -> HostsResult
    public var setRouting: (_ model: String, _ mode: String, _ hosts: [String], _ noTraining: Bool) async throws -> RoutingChoice

    public init(catalog: @escaping (String, [String]) async throws -> [CatalogModel],
                hosts: @escaping (String) async throws -> HostsResult,
                setRouting: @escaping (String, String, [String], Bool) async throws -> RoutingChoice) {
        self.catalog = catalog
        self.hosts = hosts
        self.setRouting = setRouting
    }
}

// MARK: - Formatting

public enum LKModelText {
    /// "$15" "$3.00" "$0.50" "$0.05" "$0.038" "$0.006" "Free"
    public static func price(_ value: Double?) -> String? {
        guard let value else { return nil }
        if value == 0 { return "Free" }
        if value >= 10 { return String(format: "$%.0f", value) }
        // Two decimals, a third only when it matters ($0.038, not $0.050).
        var text = String(format: "%.3f", value)
        if text.hasSuffix("0") { text.removeLast() }
        return "$" + text
    }

    /// "$0.08 in · $0.50 out per 1M tokens" (or "Free", or nil when unknown)
    public static func prices(input: Double?, output: Double?) -> String? {
        if input == 0, output == 0 { return "Free" }
        guard let i = price(input), let o = price(output) else { return nil }
        return "\(i) in · \(o) out"
    }

    /// Every word of the search appears somewhere in the given texts ("deepseek v4.1 flash").
    public static func matches(_ search: String, in texts: [String?]) -> Bool {
        let words = search.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let haystack = texts.compactMap { $0?.lowercased() }.joined(separator: " ")
        return words.allSatisfy { haystack.contains($0) }
    }

    /// 1048576 -> "1M", 131072 -> "131K"
    public static func context(_ tokens: Int?) -> String? {
        guard let tokens, tokens > 0 else { return nil }
        if tokens >= 1_000_000 { return String(format: tokens % 1_000_000 < 50_000 ? "%.0fM" : "%.1fM", Double(tokens) / 1_000_000) }
        return "\(tokens / 1000)K"
    }
}

// MARK: - The sheet

struct LKModelPickerSheet: View {
    let card: PromptCard
    let actions: LKPromptActions
    var agentName = "this agent"
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var details: [String: [String: CatalogModel]] = [:]   // provider -> model id -> details
    @State private var openRouter: [CatalogModel] = []
    @State private var switching: String?
    @State private var warning: (model: String, provider: String, message: String)?
    @State private var failure: String?
    @State private var path: [LKModelRoute] = []
    @State private var pendingScope: String?
    /// The model tapped: asks "Use / Advanced… / Cancel".
    @State private var confirming: LKModelChoice?

    private var providers: [PromptCard.ModelProvider] {
        (card.providers ?? []).sorted { $0.isCurrent && !$1.isCurrent }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let failure {
                    Text(failure).foregroundStyle(LK.Palette.danger).font(LK.Typography.footnote)
                }
                ForEach(providers, id: \.slug) { provider in
                    let models = filtered(provider)
                    if !models.isEmpty || (provider.slug == "openrouter" && !openRouter.isEmpty) {
                        Section {
                            if provider.slug == "openrouter", actions.models != nil {
                                NavigationLink(value: LKModelRoute.browse) {
                                    Label(openRouter.isEmpty ? "Browse all OpenRouter models"
                                                             : "Browse all \(openRouter.count) OpenRouter models",
                                          systemImage: "square.grid.2x2")
                                }
                            }
                            ForEach(models, id: \.self) { model in
                                row(model, provider: provider)
                            }
                        } header: {
                            Text(provider.slug == "openrouter" ? "OpenRouter — Hermes' picks" : provider.name)
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Search models")
            .navigationTitle("Choose a Model")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationDestination(for: LKModelRoute.self) { route in
                switch route {
                case .browse:
                    LKOpenRouterBrowser(models: openRouter, current: card.currentModel, switching: switching,
                                        choose: { confirming = LKModelChoice(model: $0, provider: "openrouter") })
                case .detail(let model):
                    LKModelDetail(model: model, isCurrent: model.id == card.currentModel, actions: actions,
                                  agentName: agentName,
                                  pick: { scope in pick(model.id, "openrouter", confirmed: false, scope: scope) },
                                  switching: switching)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("Switch anyway?", isPresented: Binding(get: { warning != nil }, set: { if !$0 { warning = nil } })) {
                Button("Switch Anyway") {
                    if let warning { pick(warning.model, warning.provider, confirmed: true, scope: pendingScope) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(warning?.message ?? "")
            }
            .task { await loadDetails() }
        }
        // Tapping a model: use it as it is, or open its advanced settings (hosts, routing).
        // A centred alert (a dialog would float as a popover without a Cancel button).
        .alert(confirming.map { "Use \($0.model.name ?? $0.model.id)?" } ?? "",
               isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
               presenting: confirming) { choice in
            Button("This Session Only") { pick(choice.model.id, choice.provider, confirmed: false, scope: "session") }
            Button("Always Use for \(agentName)") { pick(choice.model.id, choice.provider, confirmed: false, scope: "global") }
            if choice.provider == "openrouter", actions.models != nil {
                Button("Advanced…") { path.append(.detail(choice.model)) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { choice in
            Text(choice.provider == "openrouter"
                 ? "This session only, or saved as \(agentName)'s model from now on (other agents keep theirs). Advanced lets you choose which companies host it, and whether they may train on your data."
                 : "This session only, or saved as \(agentName)'s model from now on (other agents keep theirs).")
        }
    }

    private func filtered(_ provider: PromptCard.ModelProvider) -> [String] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return provider.models }
        if provider.name.lowercased().hasPrefix(query) { return provider.models }
        return provider.models.filter { id in
            let info = details[provider.slug]?[id]
            return LKModelText.matches(query, in: [id, info?.name, info?.maker_name])
        }
    }

    private func row(_ model: String, provider: PromptCard.ModelProvider) -> some View {
        let info = details[provider.slug]?[model] ?? CatalogModel(id: model)
        let isCurrent = provider.slug == card.currentProvider && model == card.currentModel
        return LKModelRow(model: info, label: provider.modelLabels?[model], isCurrent: isCurrent,
                          busy: switching == model) {
            confirming = LKModelChoice(model: info, provider: provider.slug)
        }
    }

    /// Prices and abilities for every listed model, and OpenRouter's full catalog.
    private func loadDetails() async {
        guard let source = actions.models else { return }
        for provider in providers {
            if let models = try? await source.catalog(provider.slug, provider.models) {
                details[provider.slug] = Dictionary(models.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                if provider.slug == "openrouter" { openRouter = models }
            }
        }
    }

    private func pick(_ model: String, _ provider: String, confirmed: Bool, scope: String? = nil) {
        switching = model
        failure = nil
        Task {
            do {
                let (status, message) = try await actions.pickModel(model, provider, confirmed, scope)
                switching = nil
                if status == "needs_confirmation" {
                    warning = (model, provider, message ?? "Hermes flagged this model.")
                    pendingScope = scope
                } else {
                    dismiss()
                }
            } catch {
                switching = nil
                failure = "Couldn't switch: \(error.localizedDescription)"
            }
        }
    }
}

enum LKModelRoute: Hashable {
    case browse
    case detail(CatalogModel)
}

struct LKModelChoice: Equatable {
    let model: CatalogModel
    let provider: String
}

// MARK: - One model

struct LKModelRow: View {
    let model: CatalogModel
    var label: String? = nil
    let isCurrent: Bool
    let busy: Bool
    let pick: () -> Void

    var body: some View {
        HStack(spacing: LK.Spacing.sm) {
            Button(action: pick) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: LK.Spacing.xs) {
                        Text(model.name ?? model.id)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if let label { LKBadge(label) }
                        if model.free == true, label?.lowercased() != "free",
                           !(model.name ?? "").lowercased().contains("free") { LKBadge("Free") }
                    }
                    if model.name != nil, model.name != model.id {
                        Text(model.id)
                            .font(LK.Typography.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    facts
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if busy {
                ProgressView()
            } else if isCurrent {
                Image(systemName: "checkmark").foregroundStyle(LK.Palette.accent)
            }
        }
        .disabled(busy)
    }

    private var facts: some View {
        HStack(spacing: LK.Spacing.sm) {
            if model.free != true, let prices = LKModelText.prices(input: model.input, output: model.output) {
                Text(prices)
            }
            if let context = LKModelText.context(model.context) {
                Label(context, systemImage: "text.alignleft")
                    .labelStyle(.titleAndIcon)
                    .accessibilityLabel("\(context) tokens of context")
            }
            if model.reasoning == true {
                Image(systemName: "brain").accessibilityLabel("Reasoning")
            }
            if model.vision == true {
                Image(systemName: "eye").accessibilityLabel("Reads images")
            }
        }
        .font(LK.Typography.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

struct LKBadge: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(LK.Typography.caption.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(LK.Palette.accent.opacity(0.15), in: Capsule())
            .foregroundStyle(LK.Palette.accent)
    }
}

// MARK: - OpenRouter's whole catalog

enum LKModelSort: String, CaseIterable, Identifiable {
    case maker = "By Maker", cheapest = "Cheapest", newest = "Newest", context = "Largest Context"
    var id: String { rawValue }
}

struct LKOpenRouterBrowser: View {
    let models: [CatalogModel]
    let current: String?
    let switching: String?
    let choose: (CatalogModel) -> Void
    @State private var search = ""
    @State private var sort: LKModelSort = .maker
    @State private var freeOnly = false
    @State private var reasoningOnly = false
    @State private var visionOnly = false

    static func filter(_ models: [CatalogModel], search: String, freeOnly: Bool,
                       reasoningOnly: Bool = false, visionOnly: Bool = false) -> [CatalogModel] {
        return models.filter { model in
            (!freeOnly || model.free == true)
                && (!reasoningOnly || model.reasoning == true)
                && (!visionOnly || model.vision == true)
                && LKModelText.matches(search, in: [model.id, model.name, model.maker_name])
        }
    }

    static func sorted(_ models: [CatalogModel], by sort: LKModelSort) -> [CatalogModel] {
        switch sort {
        case .maker: return models.sorted { ($0.name ?? $0.id).localizedCaseInsensitiveCompare($1.name ?? $1.id) == .orderedAscending }
        case .cheapest: return models.sorted { (($0.input ?? .infinity) + ($0.output ?? .infinity)) < (($1.input ?? .infinity) + ($1.output ?? .infinity)) }
        case .newest: return models.sorted { ($0.created ?? 0) > ($1.created ?? 0) }
        case .context: return models.sorted { ($0.context ?? 0) > ($1.context ?? 0) }
        }
    }

    /// Makers with the most models first.
    static func byMaker(_ models: [CatalogModel]) -> [(name: String, models: [CatalogModel])] {
        let groups = Dictionary(grouping: models) { $0.maker_name ?? $0.maker ?? "Other" }
        return groups.map { ($0.key, $0.value) }
            .sorted { $0.models.count != $1.models.count ? $0.models.count > $1.models.count : $0.name < $1.name }
    }

    var body: some View {
        let shown = Self.sorted(Self.filter(models, search: search, freeOnly: freeOnly,
                                            reasoningOnly: reasoningOnly, visionOnly: visionOnly), by: sort)
        List {
            if sort == .maker {
                ForEach(Self.byMaker(shown), id: \.name) { group in
                    Section("\(group.name) · \(group.models.count)") {
                        ForEach(group.models) { row($0) }
                    }
                }
            } else {
                Section("\(shown.count) models") {
                    ForEach(shown) { row($0) }
                }
            }
        }
        .overlay {
            if models.isEmpty {
                ProgressView("Loading OpenRouter's models…")
            } else if shown.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
        .searchable(text: $search, prompt: "Search models")
        .navigationTitle("OpenRouter")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach(LKModelSort.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Section("Show only") {
                        Toggle("Free", isOn: $freeOnly)
                        Toggle("Reasoning", isOn: $reasoningOnly)
                        Toggle("Reads Images", isOn: $visionOnly)
                    }
                } label: {
                    Label("Sort and Filter", systemImage: freeOnly || reasoningOnly || visionOnly
                          ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
            }
        }
    }

    private func row(_ model: CatalogModel) -> some View {
        LKModelRow(model: model, isCurrent: model.id == current, busy: switching == model.id) { choose(model) }
    }
}

// MARK: - A model's hosts and routing ("Advanced")

struct LKModelDetail: View {
    let model: CatalogModel
    let isCurrent: Bool
    let actions: LKPromptActions
    var agentName = "this agent"
    let pick: (_ scope: String) -> Void
    let switching: String?
    @State private var hosts: [ModelHost] = []
    @State private var mode = "balanced"
    @State private var chosen: [String] = []
    @State private var noTraining = false
    @State private var saved = RoutingChoice(mode: "balanced")
    @State private var loading = true
    @State private var failure: String?
    @State private var saving = false
    @State private var confirming = false
    @State private var savedNote: String?

    static let modes: [(value: String, title: String, detail: String)] = [
        ("balanced", "Balanced", "OpenRouter's default: price and speed together."),
        ("cheapest", "Cheapest", "Always the lowest price."),
        ("fastest", "Fastest", "The host with the highest speed right now."),
        ("one", "One Host", "Only the host you pick below."),
        ("prefer", "Prefer These", "Try the hosts you pick, in your order, then others."),
        ("only", "Only These", "Only the hosts you pick; fails if none are available."),
    ]

    private var picksHosts: Bool { mode == "one" || mode == "only" || mode == "prefer" }
    private var savedNoTraining: Bool { saved.no_training ?? false }
    private var changed: Bool {
        mode != saved.mode || (picksHosts && chosen != saved.hosts) || noTraining != savedNoTraining
    }

    var body: some View {
        List {
            Section {
                LKModelHeader(model: model, isCurrent: isCurrent, busy: switching == model.id,
                              agentName: agentName, use: pick)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section {
                Picker("Routing", selection: $mode) {
                    ForEach(Self.modes, id: \.value) { Text($0.title).tag($0.value) }
                    if saved.mode == "custom" { Text("Custom (set in Hermes)").tag("custom") }
                }
                Text(Self.modes.first { $0.value == mode }?.detail ?? "Set by hand in Hermes' config.")
                    .font(LK.Typography.footnote)
                    .foregroundStyle(.secondary)
                Toggle(isOn: $noTraining) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No training on my data")
                        Text("OpenRouter skips hosts that store or train on your prompts. Its public data doesn't say which ones, so the list below still shows all hosts.")
                            .font(LK.Typography.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                if let savedNote, !changed {
                    Label(savedNote, systemImage: "checkmark.circle.fill")
                        .font(LK.Typography.footnote)
                        .foregroundStyle(LK.Palette.success)
                }
            } header: {
                Text("Which hosts OpenRouter uses")
            } footer: {
                Text("Saved for this agent in your Hermes settings and used from its next message. A backup of the settings is kept first.")
            }

            Section {
                if loading {
                    ProgressView()
                } else if hosts.isEmpty {
                    Text("No hosts listed.").foregroundStyle(.secondary)
                }
                ForEach(hosts) { host in
                    hostRow(host)
                }
            } header: {
                Text(hosts.isEmpty ? "Hosts" : "\(hosts.count) hosts · cheapest first")
            } footer: {
                switch mode {
                case "one": Text("Tap the host to use. Touch and hold a host for its privacy policy.")
                case "prefer": Text("Tap hosts in the order to try them. Touch and hold for privacy policies.")
                case "only": Text("Tap the hosts to allow. Touch and hold for privacy policies.")
                default: Text("Touch and hold a host for its privacy policy and terms.")
                }
            }
            if let failure {
                Text(failure).foregroundStyle(LK.Palette.danger).font(LK.Typography.footnote)
            }
        }
        // Pinned at the bottom, so it's at hand after picking hosts further down.
        .safeAreaInset(edge: .bottom) {
            if changed {
                Button {
                    confirming = true
                } label: {
                    Text(saving ? "Saving…" : "Save Routing").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(LK.Palette.accent)
                .controlSize(.large)
                .disabled(saving || (picksHosts && chosen.isEmpty))
                .padding(.horizontal, LK.Spacing.lg)
                .padding(.vertical, LK.Spacing.sm)
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
        }
        // Unsaved choices aren't lost to an accidental swipe down.
        .interactiveDismissDisabled(changed)
        .onChange(of: mode) { _, newMode in
            if newMode == saved.mode {
                chosen = saved.hosts
            } else if newMode == "one" {
                chosen = Array(chosen.prefix(1))
            } else {
                chosen = []
            }
        }
        .navigationTitle(model.maker_name ?? "Model")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
        .alert("Save routing for this model?", isPresented: $confirming) {
            Button("Save") { save() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This changes your Hermes settings for \(model.name ?? model.id) (this agent only). A backup is kept, so it can be undone.")
        }
    }

    private func hostRow(_ host: ModelHost) -> some View {
        let position = chosen.firstIndex(of: host.tag)
        return Button {
            guard picksHosts else { return }
            if mode == "one" {
                chosen = [host.tag]
            } else if let position {
                chosen.remove(at: position)
            } else {
                chosen.append(host.tag)
            }
        } label: {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: LK.Spacing.xs) {
                        if let flag = Self.flag(host.country) { Text(flag) }
                        Text(host.name).foregroundStyle(.primary)
                        // Same company, different setups ("wafer/us", "inference-net/fp8"): tell them apart.
                        ForEach(Self.variant(of: host), id: \.self) { LKBadge($0) }
                        if let discount = host.discount, discount > 0 { LKBadge("\(Int(discount * 100))% off") }
                    }
                    HStack(spacing: LK.Spacing.sm) {
                        if let prices = LKModelText.prices(input: host.input, output: host.output) { Text(prices) }
                        if let uptime = host.uptime { Text(String(format: "%.1f%% up", uptime)) }
                        if let context = LKModelText.context(host.context) { Text(context) }
                    }
                    .font(LK.Typography.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if picksHosts, let position {
                    if mode == "prefer" {
                        Text("\(position + 1)")
                            .font(LK.Typography.captionStrong)
                            .foregroundStyle(LK.Palette.onAccent)
                            .frame(width: 22, height: 22)
                            .background(LK.Palette.accent, in: Circle())
                    } else {
                        Image(systemName: mode == "one" ? "checkmark.circle.fill" : "checkmark")
                            .foregroundStyle(LK.Palette.accent)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let url = host.privacy_url.flatMap(URL.init(string:)) { Link("Privacy Policy", destination: url) }
            if let url = host.terms_url.flatMap(URL.init(string:)) { Link("Terms of Service", destination: url) }
        }
    }

    /// "wafer/us" + mxfp4 -> ["US", "MXFP4"]; "deepinfra/fp8/flex" -> ["FP8", "FLEX"].
    static func variant(of host: ModelHost) -> [String] {
        // The country is already shown as a flag.
        var parts = host.tag.split(separator: "/").dropFirst().map { $0.uppercased() }
            .filter { $0 != host.country?.uppercased() }
        if let quant = host.quantization?.uppercased(), !parts.contains(quant) { parts.append(quant) }
        return parts
    }

    /// "US" -> 🇺🇸
    static func flag(_ country: String?) -> String? {
        guard let code = country?.uppercased(), code.count == 2,
              code.unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) }) else { return nil }
        return String(String.UnicodeScalarView(code.unicodeScalars.compactMap { UnicodeScalar(127_397 + $0.value) }))
    }

    private func load() async {
        guard let source = actions.models else { return }
        do {
            let result = try await source.hosts(model.id)
            hosts = result.hosts
            saved = result.routing
            mode = result.routing.mode
            chosen = result.routing.hosts
            noTraining = result.routing.no_training ?? false
        } catch {
            failure = "Couldn't load the hosts: \(error.localizedDescription)"
        }
        loading = false
    }

    private func save() {
        guard let source = actions.models else { return }
        saving = true
        failure = nil
        Task {
            do {
                let result = try await source.setRouting(model.id, mode, picksHosts ? chosen : [], noTraining)
                saved = result
                chosen = result.hosts
                noTraining = result.no_training ?? false
                savedNote = result.backup == nil ? "Already set" : "Saved"
            } catch {
                failure = "Couldn't save: \(error.localizedDescription)"
            }
            saving = false
        }
    }
}

/// The model at the top of its page: a designed summary, not a list of controls.
struct LKModelHeader: View {
    let model: CatalogModel
    let isCurrent: Bool
    let busy: Bool
    var agentName = "this agent"
    let use: (_ scope: String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: LK.Spacing.md) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    if let maker = model.maker_name {
                        Text(maker.uppercased())
                            .font(LK.Typography.caption.weight(.semibold))
                            .tracking(1)
                            .foregroundStyle(.secondary)
                    }
                    Text(model.name ?? model.id)
                        .font(.title2.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(model.id)
                        .font(LK.Typography.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer(minLength: LK.Spacing.sm)
                if isCurrent {
                    Text("In use")
                        .font(LK.Typography.captionStrong)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(LK.Palette.success.opacity(0.2), in: Capsule())
                        .foregroundStyle(LK.Palette.success)
                }
            }

            HStack(spacing: LK.Spacing.sm) {
                stat(model.free == true ? "Free" : LKModelText.price(model.input) ?? "—", "Input", "per 1M")
                stat(model.free == true ? "Free" : LKModelText.price(model.output) ?? "—", "Output", "per 1M")
                stat(LKModelText.context(model.context) ?? "—", "Context", "tokens")
            }

            HStack(spacing: LK.Spacing.xs) {
                chip("Tools", "wrench.and.screwdriver")
                if model.reasoning == true { chip("Reasoning", "brain") }
                if model.vision == true { chip("Images", "eye") }
            }

            if !isCurrent {  // the badge already says so for the model in use
                Menu {
                    Button("This Session Only", systemImage: "bubble.left") { use("session") }
                    Button("Always Use for \(agentName)", systemImage: "star") { use("global") }
                } label: {
                    HStack {
                        if busy { ProgressView().tint(LK.Palette.onAccent) }
                        Text("Use This Model")
                        Image(systemName: "chevron.down").font(.caption.weight(.bold))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(LK.Palette.accent)
                .controlSize(.large)
                .disabled(busy)
            }
        }
        .padding(LK.Spacing.lg)
        .background(
            LinearGradient(colors: [LK.Palette.accent.opacity(0.22), LK.Palette.accent.opacity(0.06)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: LK.Radius.card, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func stat(_ value: String, _ title: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(unit)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(LK.Spacing.sm)
        .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: LK.Radius.small, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func chip(_ title: String, _ symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(LK.Typography.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.background.opacity(0.55), in: Capsule())
    }
}

#Preview("Model header") {
    List {
        LKModelHeader(model: CatalogModel(id: "deepseek/deepseek-v4.1-flash-1017", name: "DeepSeek V4.1 Flash 1017",
                                          maker: "deepseek", maker_name: "DeepSeek", context: 1_048_576, input: 0.006,
                                          output: 0.5, free: false, reasoning: true, vision: true),
                      isCurrent: true, busy: false, use: { _ in })
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
    }
    .preferredColorScheme(.dark)
}
