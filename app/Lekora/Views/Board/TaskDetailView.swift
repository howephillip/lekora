import SwiftUI

/// One task (docs/kanban.md): what it is, how it's going (summary, runs, history), comments, and
/// what it waits on. Every change goes to Hermes' board, whose rules decide.
struct TaskDetailView: View {
    @ObservedObject var gateway: GatewayClient
    let boardSlug: String
    let taskId: String
    /// The board it was opened from (its statuses and allowed moves).
    let board: KanbanBoardResult?

    @State private var detail: KanbanTaskResult?
    @State private var failure: String?
    @State private var problem: String?
    @State private var comment = ""
    @State private var sending = false
    @State private var editing = false
    @State private var addingWait = false
    /// A move that asks for a few words first (why it's blocked, what was done).
    @State private var asking: String?
    @State private var note = ""
    @State private var confirmingStop = false
    @State private var assigning = false
    @FocusState private var composing: Bool

    private var agents: [ProfileData] { gateway.profiles }

    var body: some View {
        content
            .navigationTitle(detail?.task.title ?? "Task")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                if let task = detail?.task {
                    ToolbarItem(placement: .primaryAction) { actionsMenu(task) }
                }
            }
            .safeAreaInset(edge: .bottom) { composer }
            .sheet(isPresented: $editing) {
                if let board, let task = detail?.task {
                    TaskEditorView(gateway: gateway, board: board, task: task) { _ in Task { await load() } }
                }
            }
            .sheet(isPresented: $addingWait) {
                if let board, let task = detail?.task {
                    WaitPickerView(board: board, task: task, already: Set(detail?.parents.map(\.id) ?? [])) { parent in
                        change { try await gateway.linkTask(task.id, on: boardSlug, waitsOn: parent) }
                    }
                }
            }
            .alert(asking.map { $0 == "done" ? "What Was Done?" : "Why Is It Blocked?" } ?? "",
                   isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } })) {
                TextField(asking == "done" ? "A short note (optional)" : "A reason (optional)", text: $note)
                Button("Cancel", role: .cancel) { note = "" }
                Button(asking == "done" ? "Mark Done" : "Block") {
                    let status = asking ?? "", words = note.trimmingCharacters(in: .whitespacesAndNewlines)
                    note = ""
                    change { try await gateway.moveTask(taskId, on: boardSlug, to: status, note: words.isEmpty ? nil : words) }
                }
            } message: {
                Text(asking == "done" ? "Hermes keeps it with the task." : "The agent sees this when it picks the task up again.")
            }
            .sheet(isPresented: $assigning) {
                NavigationStack {
                    List {
                        assignRow(nil, name: "Nobody")
                        ForEach(agents) { agent in assignRow(agent.profile_id, name: agent.name) }
                    }
                    .navigationTitle("Assign To")
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { assigning = false } }
                    }
                }
                .presentationDetents([.medium, .large])
            }
            .alert("Couldn't Do That", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(problem ?? "")
            }
            .task { await load() }
            .task(id: gateway.kanbanChanges) {
                guard detail != nil, let change = gateway.lastKanbanChange, change.board == boardSlug,
                      change.task_ids.contains(taskId) || change.task_ids.contains(where: linked.contains) else { return }
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                await load()
            }
            .refreshable { await load() }
    }

    private var linked: Set<String> {
        Set((detail?.parents ?? []).map(\.id) + (detail?.children ?? []).map(\.id))
    }

    @ViewBuilder
    private var content: some View {
        if let detail {
            details(detail)
        } else if let failure {
            ContentUnavailableView {
                Label("Couldn't Load It", systemImage: "exclamationmark.triangle")
            } description: {
                Text(failure)
            } actions: {
                Button("Try Again") { Task { await load() } }
            }
        } else {
            ProgressView()
        }
    }

    private func details(_ detail: KanbanTaskResult) -> some View {
        let task = detail.task
        return List {
            Section {
                VStack(alignment: .leading, spacing: LK.Spacing.sm) {
                    Text(task.title).font(LK.Typography.title)
                    HStack(spacing: LK.Spacing.sm) {
                        Label(KanbanBoard.label(task.status, in: board), systemImage: KanbanBoard.symbol(task.status))
                            .font(LK.Typography.captionStrong)
                            .foregroundStyle(KanbanBoard.tint(task.status))
                            .padding(.horizontal, LK.Spacing.sm)
                            .padding(.vertical, LK.Spacing.xxs)
                            .background(LK.Surface.inset, in: Capsule())
                        if let priority = KanbanBoard.priorityLabel(task.priority) {
                            Text(priority).font(LK.Typography.captionStrong).foregroundStyle(.orange)
                        }
                        if task.status == "running", let since = task.running_since {
                            TimelineView(.periodic(from: .now, by: 30)) { context in
                                Text("Running for \(KanbanBoard.duration(context.date.timeIntervalSince1970 - since))")
                                    .font(LK.Typography.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .listRowSeparator(.hidden, edges: .bottom)
                LabeledContent("Agent", value: KanbanBoard.agentName(task.assignee, among: agents) ?? "Nobody")
                if let created = KanbanBoard.date(task.created_at) {
                    LabeledContent("Added", value: created.formatted(.relative(presentation: .named)))
                }
                if let failures = task.failures, failures > 0 {
                    LabeledContent("Failed attempts", value: "\(failures)")
                }
            }
            if task.status == "running" {
                Section {
                    Button(role: .destructive) { confirmingStop = true } label: {
                        Label("Stop This Task", systemImage: "stop.circle").foregroundStyle(.red)
                    }
                    .confirmationDialog("Stop this task?", isPresented: $confirmingStop, titleVisibility: .visible) {
                        Button("Stop", role: .destructive) {
                            change { try await gateway.stopTask(taskId, on: boardSlug) }
                        }
                    } message: {
                        Text("Hermes stops the agent working on it. The task waits as Blocked until you move it again.")
                    }
                }
            }
            if let body = task.body, !body.isEmpty {
                Section("Description") { Text(LocalizedStringKey(body)).textSelection(.enabled) }
            }
            if let summary = task.summary {
                Section("Latest Summary") { Text(LocalizedStringKey(summary)).textSelection(.enabled) }
            }
            if let result = task.result, result != task.summary {
                Section("Result") { Text(LocalizedStringKey(result)).textSelection(.enabled) }
            }
            if let error = task.last_error {
                Section("Last Problem") { Text(error).font(LK.Typography.callout).foregroundStyle(.red).textSelection(.enabled) }
            }
            Section {
                ForEach(detail.parents) { parent in
                    linkedRow(parent)
                        .swipeActions {
                            Button("Remove", role: .destructive) {
                                change { try await gateway.linkTask(task.id, on: boardSlug, waitsOn: parent.id, remove: true) }
                            }
                        }
                }
                Button("Add a Task It Waits On…", systemImage: "link.badge.plus") { addingWait = true }
                    .disabled(board == nil || task.status == KanbanBoard.archived)
            } header: {
                Text("Waits On")
            } footer: {
                Text("Hermes starts it only when these are done.")
            }
            if !detail.children.isEmpty {
                Section("Waiting on This") {
                    ForEach(detail.children) { linkedRow($0) }
                }
            }
            Section("Comments") {
                if detail.comments.isEmpty {
                    Text("No comments yet. Agents read them when they work on the task.")
                        .font(LK.Typography.callout).foregroundStyle(.secondary)
                }
                ForEach(detail.comments) { comment in
                    VStack(alignment: .leading, spacing: LK.Spacing.xxs) {
                        HStack {
                            Text(author(comment.author))
                                .font(LK.Typography.captionStrong)
                            Spacer()
                            Text(Date(timeIntervalSince1970: comment.created_at).formatted(.relative(presentation: .named)))
                                .font(LK.Typography.caption).foregroundStyle(.secondary)
                        }
                        Text(LocalizedStringKey(comment.body)).font(LK.Typography.callout).textSelection(.enabled)
                    }
                }
            }
            if !detail.runs.isEmpty {
                Section("Runs") {
                    ForEach(detail.runs.reversed()) { run in runRow(run) }
                }
            }
            if !detail.events.isEmpty {
                Section("History") {
                    ForEach(detail.events.reversed()) { event in
                        HStack(alignment: .firstTextBaseline) {
                            Text(event.summary).font(LK.Typography.callout).lineLimit(3)
                            Spacer()
                            Text(Date(timeIntervalSince1970: event.created_at).formatted(.relative(presentation: .named)))
                                .font(LK.Typography.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.interactively)
    }

    /// You (your name, or "user" before you chose one), an agent's name, or as Hermes has it.
    private func author(_ who: String) -> String {
        if who == "user" || (gateway.userName?.isEmpty == false && who == gateway.userName) { return "You" }
        return KanbanBoard.agentName(who, among: agents) ?? who
    }

    private func linkedRow(_ other: KanbanLinked) -> some View {
        NavigationLink {
            TaskDetailView(gateway: gateway, boardSlug: boardSlug, taskId: other.id, board: board)
        } label: {
            HStack {
                Image(systemName: KanbanBoard.symbol(other.status)).foregroundStyle(.secondary)
                Text(other.title).lineLimit(2)
                Spacer()
                Text(KanbanBoard.label(other.status, in: board)).font(LK.Typography.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func runRow(_ run: KanbanRun) -> some View {
        VStack(alignment: .leading, spacing: LK.Spacing.xxs) {
            HStack {
                Text(KanbanBoard.agentName(run.profile, among: agents) ?? "Run \(run.id)")
                    .font(LK.Typography.captionStrong)
                Text((run.outcome ?? run.status).replacingOccurrences(of: "_", with: " ").capitalized)
                    .font(LK.Typography.caption)
                    .foregroundStyle(run.ended_at == nil ? LK.Palette.accent : .secondary)
                Spacer()
                if let start = run.started_at {
                    Text(runTime(start: start, end: run.ended_at)).font(LK.Typography.caption).foregroundStyle(.secondary)
                }
            }
            if let summary = run.summary {
                Text(LocalizedStringKey(summary)).font(LK.Typography.callout).lineLimit(6).textSelection(.enabled)
            }
            if let error = run.error {
                Text(error).font(LK.Typography.caption).foregroundStyle(.red).lineLimit(4)
            }
        }
    }

    private func runTime(start: Double, end: Double?) -> String {
        let when = Date(timeIntervalSince1970: start).formatted(.relative(presentation: .named))
        guard let end else { return "started \(when)" }
        return "\(when) · \(KanbanBoard.duration(end - start))"
    }

    // MARK: - Actions

    // Flat: choices in a submenu of a toolbar menu didn't run (seen in the simulator).
    private func actionsMenu(_ task: KanbanCard) -> some View {
        Menu {
            Button("Edit", systemImage: "pencil") { editing = true }.disabled(board == nil)
            Button("Assign To…", systemImage: "person") { assigning = true }
            if task.status == "running" {
                Button("Stop", systemImage: "stop.circle", role: .destructive) { confirmingStop = true }
            }
            if let board {
                Section {
                    ForEach(KanbanBoard.moves(for: task, in: board).filter { $0 != KanbanBoard.archived }, id: \.self) { status in
                        Button(KanbanBoard.moveTitle(status, from: task.status, in: board), systemImage: KanbanBoard.symbol(status)) {
                            move(to: status)
                        }
                    }
                }
            }
            if task.status != KanbanBoard.archived {
                Section {
                    Button("Archive", systemImage: "archivebox") { move(to: KanbanBoard.archived) }
                }
            }
        } label: {
            Label("Actions", systemImage: "ellipsis")
        }
    }

    private func assignRow(_ profileId: String?, name: String) -> some View {
        Button {
            assigning = false
            if profileId != detail?.task.assignee { assign(profileId) }
        } label: {
            HStack {
                Text(name).foregroundStyle(.primary)
                Spacer()
                if profileId == detail?.task.assignee {
                    Image(systemName: "checkmark").foregroundStyle(LK.Palette.accent)
                }
            }
        }
    }

    private func assign(_ assignee: String?) {
        change { try await gateway.assignTask(taskId, on: boardSlug, to: assignee) }
    }

    private func move(to status: String) {
        if status == "done" || status == "blocked" {
            asking = status
            return
        }
        change { try await gateway.moveTask(taskId, on: boardSlug, to: status) }
    }

    @ViewBuilder
    private var composer: some View {
        if detail != nil {
            HStack(alignment: .bottom, spacing: LK.Spacing.sm) {
                TextField("Add a comment", text: $comment, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($composing)
                    .padding(.horizontal, LK.Spacing.md)
                    .padding(.vertical, LK.Spacing.sm)
                    .background(LK.Surface.inset, in: RoundedRectangle(cornerRadius: LK.Radius.bubble))
                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title)
                }
                .disabled(sending || comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Send Comment")
            }
            .padding(.horizontal, LK.Spacing.lg)
            .padding(.vertical, LK.Spacing.sm)
            .background(.bar)
        }
    }

    private func send() {
        let text = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sending = true
        Task {
            defer { sending = false }
            do {
                try await gateway.commentOnTask(taskId, on: boardSlug, text)
                comment = ""
                composing = false
                await load()
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func change(_ action: @escaping () async throws -> KanbanCard) {
        Task {
            do {
                _ = try await action()
                await load()
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func load() async {
        do {
            detail = try await gateway.kanbanTask(taskId, board: boardSlug)
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// Choosing a task this one waits on.
struct WaitPickerView: View {
    let board: KanbanBoardResult
    let task: KanbanCard
    let already: Set<String>
    let chosen: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var candidates: [KanbanCard] {
        let words = query.trimmingCharacters(in: .whitespaces).lowercased()
        return board.tasks.filter { other in
            other.id != task.id && !already.contains(other.id) && other.status != KanbanBoard.archived
                && (words.isEmpty || other.title.lowercased().contains(words))
        }
    }

    var body: some View {
        NavigationStack {
            List(candidates) { other in
                Button {
                    chosen(other.id)
                    dismiss()
                } label: {
                    HStack {
                        Image(systemName: KanbanBoard.symbol(other.status)).foregroundStyle(.secondary)
                        Text(other.title).foregroundStyle(.primary).lineLimit(2)
                        Spacer()
                        Text(KanbanBoard.label(other.status, in: board)).font(LK.Typography.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .overlay {
                if candidates.isEmpty { ContentUnavailableView.search(text: query) }
            }
            .searchable(text: $query, prompt: "Search tasks")
            .navigationTitle("Waits On")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}
