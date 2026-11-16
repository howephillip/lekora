import SwiftUI

/// A new task, or editing one (docs/kanban.md): title, description, agent, priority, and for a new
/// one, what it waits on and whether it starts in Triage.
struct TaskEditorView: View {
    @ObservedObject var gateway: GatewayClient
    let board: KanbanBoardResult
    /// nil: a new task.
    let task: KanbanCard?
    let saved: (KanbanCard) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var details = ""
    @State private var assignee: String?
    @State private var priority = 0
    @State private var waitsOn: Set<String> = []
    @State private var triage = false
    @State private var saving = false
    @State private var problem: String?
    @State private var choosingWaits = false
    @FocusState private var titleFocused: Bool

    private var isNew: Bool { task == nil }
    private var agents: [ProfileData] { gateway.profiles }
    private var canSave: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !saving }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title, axis: .vertical)
                        .font(LK.Typography.headline)
                        .focused($titleFocused)
                    TextField("Description (what to do, what done looks like)", text: $details, axis: .vertical)
                        .lineLimit(4...12)
                }
                Section {
                    if isNew {
                        Picker("Agent", selection: $assignee) {
                            Text("Nobody yet").tag(String?.none)
                            ForEach(agents) { agent in Text(agent.name).tag(String?.some(agent.profile_id)) }
                        }
                    }
                    Picker("Priority", selection: $priority) {
                        ForEach(priorityChoices, id: \.self) { value in
                            Text(priorityName(value)).tag(value)
                        }
                    }
                } footer: {
                    if isNew {
                        Text("Hermes gives it to the agent when it's ready. Higher priority goes first.")
                    }
                }
                if isNew {
                    Section {
                        Button {
                            choosingWaits = true
                        } label: {
                            LabeledContent("Waits On", value: waitsOn.isEmpty ? "Nothing" : "\(waitsOn.count) task\(waitsOn.count == 1 ? "" : "s")")
                        }
                        Toggle("Start in Triage", isOn: $triage)
                    } footer: {
                        Text("In Triage, it waits for you to look at it before any agent starts.")
                    }
                }
                if let problem {
                    Section { LKNotice(.warning, problem) }
                }
            }
            .navigationTitle(isNew ? "New Task" : "Edit Task")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Add" : "Save") { save() }.disabled(!canSave)
                }
            }
            .sheet(isPresented: $choosingWaits) {
                WaitsOnChooser(board: board, chosen: $waitsOn)
            }
            .onAppear {
                if let task {
                    title = task.title
                    details = task.body ?? ""
                    assignee = task.assignee
                    priority = task.priority
                } else {
                    titleFocused = true
                }
            }
        }
    }

    private var priorityChoices: [Int] {
        Array(Set([0, 1, 2, 3, 5, 10, -1, priority])).sorted(by: >)
    }

    private func priorityName(_ value: Int) -> String {
        switch value {
        case 0: return "Normal"
        case ..<0: return "Low (\(value))"
        default: return "Higher (P\(value))"
        }
    }

    private func save() {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanBody = details.trimmingCharacters(in: .whitespacesAndNewlines)
        saving = true
        problem = nil
        Task {
            defer { saving = false }
            do {
                let card: KanbanCard
                if let task {
                    card = try await gateway.editTask(task.id, on: board.board, title: cleanTitle, body: cleanBody, priority: priority)
                } else {
                    card = try await gateway.createTask(on: board.board, title: cleanTitle, body: cleanBody.isEmpty ? nil : cleanBody,
                                                        assignee: assignee, priority: priority,
                                                        waitsOn: board.tasks.map(\.id).filter(waitsOn.contains), triage: triage)
                }
                saved(card)
                dismiss()
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

/// Choosing the tasks a new one waits on.
private struct WaitsOnChooser: View {
    let board: KanbanBoardResult
    @Binding var chosen: Set<String>
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var candidates: [KanbanCard] {
        let words = query.trimmingCharacters(in: .whitespaces).lowercased()
        return board.tasks.filter {
            $0.status != KanbanBoard.archived && $0.status != "done" && (words.isEmpty || $0.title.lowercased().contains(words))
        }
    }

    var body: some View {
        NavigationStack {
            List(candidates) { task in
                Button {
                    if chosen.contains(task.id) { chosen.remove(task.id) } else { chosen.insert(task.id) }
                } label: {
                    HStack {
                        Image(systemName: chosen.contains(task.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(chosen.contains(task.id) ? LK.Palette.accent : .secondary)
                        Text(task.title).foregroundStyle(.primary).lineLimit(2)
                        Spacer()
                        Text(KanbanBoard.label(task.status, in: board)).font(LK.Typography.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .overlay {
                if candidates.isEmpty { ContentUnavailableView("No Open Tasks", systemImage: "link") }
            }
            .searchable(text: $query, prompt: "Search tasks")
            .navigationTitle("Waits On")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
