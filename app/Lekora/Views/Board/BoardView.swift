import SwiftUI

/// The board (docs/kanban.md): Hermes' kanban board on this instance, shared by every agent.
/// A list by default (one section per status), columns side by side as an option.
struct BoardView: View {
    enum Layout: String { case list, columns }

    @ObservedObject var gateway: GatewayClient
    @AppStorage("boardLayout") private var layoutChoice = Layout.list.rawValue
    @State private var board: KanbanBoardResult?
    @State private var boardSlug: String?
    @State private var failure: String?
    /// nil: everyone's; "": nobody's; else that agent's.
    @State private var assignee: String?
    @State private var showArchived = false
    @State private var creating = false
    @State private var problem: String?
    @State private var expanded: Set<String> = []

    private static let finishedShown = 10

    private var layout: Layout { Layout(rawValue: layoutChoice) ?? .list }
    private var connected: Bool {
        if case .connected = gateway.state { return true }
        return false
    }
    private var agents: [ProfileData] { gateway.profiles }

    var body: some View {
        content
            .navigationTitle(title)
            .navigationSubtitle(gateway.savedHost?.instanceName ?? "")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { creating = true } label: { Label("New Task", systemImage: "plus") }
                        .disabled(board == nil || !connected)
                }
                ToolbarItem(placement: .primaryAction) { optionsMenu }
            }
            .sheet(isPresented: $creating) {
                if let board {
                    TaskEditorView(gateway: gateway, board: board, task: nil) { _ in Task { await load() } }
                }
            }
            .alert("Couldn't Do That", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(problem ?? "")
            }
            .task(id: "\(boardSlug ?? "")-\(showArchived)-\(connected)") { await load() }
            // Changed elsewhere (an agent, Hermes, another phone): a moment later, load again.
            .task(id: gateway.kanbanChanges) {
                guard board != nil, gateway.lastKanbanChange?.board == board?.board else { return }
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                await load()
            }
            .refreshable { await load() }
    }

    private var title: String {
        guard let board, board.boards.count > 1 else { return "Board" }
        return board.boards.first { $0.slug == board.board }?.name ?? "Board"
    }

    @ViewBuilder
    private var content: some View {
        if let board {
            let sections = KanbanBoard.sections(board, assignee: assignee, includeEmpty: layout == .columns)
            if sections.allSatisfy({ $0.tasks.isEmpty }) {
                ContentUnavailableView {
                    Label(assignee == nil ? "No Tasks Yet" : "No Tasks for This Agent", systemImage: "square.stack.3d.up")
                } description: {
                    Text("Tasks you or your agents add to Hermes' board show here.")
                } actions: {
                    Button("New Task") { creating = true }.disabled(!connected)
                }
            } else if layout == .columns {
                columns(sections, board: board)
            } else {
                list(sections, board: board)
            }
        } else if !connected {
            ContentUnavailableView("Not Connected", systemImage: "wifi.slash",
                                   description: Text("The board is on \(gateway.savedHost?.instanceName ?? "your Hermes instance"). It shows when Lekora can reach it."))
        } else if let failure {
            ContentUnavailableView {
                Label("Couldn't Load the Board", systemImage: "exclamationmark.triangle")
            } description: {
                Text(failure)
            } actions: {
                Button("Try Again") { Task { await load() } }
            }
        } else {
            ProgressView()
        }
    }

    // MARK: - Lists

    private func list(_ sections: [KanbanBoard.Section], board: KanbanBoardResult) -> some View {
        List {
            ForEach(sections) { section in
                Section {
                    ForEach(shown(section)) { task in
                        NavigationLink {
                            TaskDetailView(gateway: gateway, boardSlug: board.board, taskId: task.id, board: board)
                        } label: {
                            KanbanCardRow(task: task, agents: agents)
                        }
                        .contextMenu { quickActions(task, board: board) }
                        .swipeActions(edge: .trailing) {
                            if task.status != KanbanBoard.archived {
                                Button("Archive", systemImage: "archivebox") { move(task, to: KanbanBoard.archived) }
                                    .tint(.gray)
                            }
                        }
                    }
                    moreButton(section)
                } header: {
                    Label("\(section.label) · \(section.tasks.count)", systemImage: KanbanBoard.symbol(section.key))
                        .font(LK.Typography.subheadline.weight(.semibold))
                        .textCase(nil)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    /// Done and Archived fold to their newest few.
    private func shown(_ section: KanbanBoard.Section) -> [KanbanCard] {
        let folds = section.key == "done" || section.key == KanbanBoard.archived
        return folds && !expanded.contains(section.key) ? Array(section.tasks.prefix(Self.finishedShown)) : section.tasks
    }

    @ViewBuilder
    private func moreButton(_ section: KanbanBoard.Section) -> some View {
        if shown(section).count < section.tasks.count {
            Button("Show All \(section.tasks.count)") { expanded.insert(section.key) }
                .font(LK.Typography.callout)
        }
    }

    // MARK: - Columns

    private func columns(_ sections: [KanbanBoard.Section], board: KanbanBoardResult) -> some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: LK.Spacing.md) {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: LK.Spacing.sm) {
                        Label("\(section.label) · \(section.tasks.count)", systemImage: KanbanBoard.symbol(section.key))
                            .font(LK.Typography.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, LK.Spacing.xs)
                        ScrollView {
                            LazyVStack(spacing: LK.Spacing.sm) {
                                ForEach(shown(section)) { task in
                                    NavigationLink {
                                        TaskDetailView(gateway: gateway, boardSlug: board.board, taskId: task.id, board: board)
                                    } label: {
                                        KanbanCardRow(task: task, agents: agents)
                                            .padding(LK.Spacing.md)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(Color(uiColor: .secondarySystemGroupedBackground),
                                                        in: RoundedRectangle(cornerRadius: LK.Radius.small))
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu { quickActions(task, board: board) }
                                }
                                moreButton(section)
                                if section.tasks.isEmpty {
                                    Text("Nothing here")
                                        .font(LK.Typography.caption)
                                        .foregroundStyle(.tertiary)
                                        .padding(.vertical, LK.Spacing.lg)
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                    }
                    .frame(width: 280)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(LK.Spacing.sm)
                    .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: LK.Radius.bubble))
                }
            }
            .padding(LK.Spacing.lg)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    // MARK: - Actions

    @ViewBuilder
    private func quickActions(_ task: KanbanCard, board: KanbanBoardResult) -> some View {
        let moves = KanbanBoard.moves(for: task, in: board)
        ForEach(moves.filter { $0 != KanbanBoard.archived }, id: \.self) { status in
            Button(KanbanBoard.moveTitle(status, from: task.status, in: board), systemImage: KanbanBoard.symbol(status)) {
                move(task, to: status)
            }
        }
        if moves.contains(KanbanBoard.archived) {
            Divider()
            Button("Archive", systemImage: "archivebox") { move(task, to: KanbanBoard.archived) }
        }
    }

    private func move(_ task: KanbanCard, to status: String) {
        Task {
            do {
                let moved = try await gateway.moveTask(task.id, on: board?.board, to: status)
                if let index = board?.tasks.firstIndex(where: { $0.id == moved.id }) {
                    if moved.status == KanbanBoard.archived && !showArchived {
                        board?.tasks.remove(at: index)
                    } else {
                        board?.tasks[index] = moved
                    }
                }
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private var optionsMenu: some View {
        Menu {
            Picker("Layout", selection: $layoutChoice) {
                Label("Lists", systemImage: "list.bullet").tag(Layout.list.rawValue)
                Label("Columns", systemImage: "rectangle.split.3x1").tag(Layout.columns.rawValue)
            }
            .pickerStyle(.inline)
            Picker(selection: $assignee) {
                Text("Everyone").tag(String?.none)
                Text("Nobody").tag(String?.some(""))
                ForEach(agents) { agent in
                    Text(agent.name).tag(String?.some(agent.profile_id))
                }
            } label: {
                Label("Show Tasks For", systemImage: "person.2")
            }
            .pickerStyle(.menu)
            Toggle("Show Archived", systemImage: "archivebox", isOn: $showArchived)
            if let board, board.boards.count > 1 {
                Picker(selection: Binding(get: { boardSlug ?? board.board }, set: { boardSlug = $0 })) {
                    ForEach(board.boards) { info in
                        Text(info.name).tag(info.slug)
                    }
                } label: {
                    Label("Board", systemImage: "square.stack.3d.up")
                }
                .pickerStyle(.menu)
            }
        } label: {
            Label("Options", systemImage: "line.3.horizontal.decrease")
        }
    }

    private func load() async {
        guard connected else { return }
        do {
            board = try await gateway.kanbanBoard(boardSlug, archived: showArchived)
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// A task on the board: title, who it's for, and how it's going.
struct KanbanCardRow: View {
    let task: KanbanCard
    let agents: [ProfileData]

    var body: some View {
        VStack(alignment: .leading, spacing: LK.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: LK.Spacing.xs) {
                Image(systemName: KanbanBoard.symbol(task.status))
                    .foregroundStyle(KanbanBoard.tint(task.status))
                    .font(LK.Typography.subheadline)
                Text(task.title)
                    .font(LK.Typography.body)
                    .lineLimit(3)
            }
            if let summary = task.summary {
                Text(summary)
                    .font(LK.Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: LK.Spacing.sm) { details }
                VStack(alignment: .leading, spacing: LK.Spacing.xxs) { details }
            }
            .font(LK.Typography.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, LK.Spacing.xxs)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var details: some View {
        if let name = KanbanBoard.agentName(task.assignee, among: agents) {
            Label(name, systemImage: "person")
        }
        if let priority = KanbanBoard.priorityLabel(task.priority) {
            Text(priority).fontWeight(.semibold).foregroundStyle(task.priority > 0 ? Color.orange : .secondary)
        }
        if task.status == "running", let since = task.running_since {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Label(KanbanBoard.duration(context.date.timeIntervalSince1970 - since), systemImage: "timer")
            }
        }
        if task.waits_on > 0 {
            Label("Waits on \(task.waits_on)", systemImage: "link")
        }
        if task.comments > 0 {
            Label("\(task.comments)", systemImage: "text.bubble")
        }
    }
}

extension KanbanBoard {
    /// Each status's colour, the same everywhere.
    static func tint(_ status: String) -> Color {
        switch status {
        case "running": return LK.Palette.accent
        case "blocked": return LK.Palette.danger
        case "done": return LK.Palette.success
        case "review": return .purple
        case "ready": return .teal
        default: return .secondary
        }
    }
}
