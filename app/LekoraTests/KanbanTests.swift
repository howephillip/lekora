import XCTest
@testable import Lekora

/// The board (docs/kanban.md).
final class KanbanTests: XCTestCase {
    private func board(_ tasks: [KanbanCard]) -> KanbanBoardResult {
        KanbanBoardResult(
            board: "default", boards: [],
            columns: ["triage", "todo", "ready", "running", "blocked", "done"].map { KanbanColumn(key: $0, label: $0.capitalized) },
            moves: ["todo": ["triage", "ready", "archived"], "running": ["ready", "blocked", "done", "archived"],
                    "done": ["todo", "ready", "archived"], "archived": ["triage", "todo", "ready"]],
            tasks: tasks)
    }

    func testTasksAreGroupedInHermesOrder() {
        let b = board([
            KanbanCard(id: "a", title: "Low", status: "todo", assignee: "coder", priority: 0, created_at: 2),
            KanbanCard(id: "b", title: "Urgent", status: "todo", assignee: "writer", priority: 5, created_at: 1),
            KanbanCard(id: "c", title: "Shipped", status: "done", completed_at: 10),
            KanbanCard(id: "d", title: "Older", status: "done", completed_at: 5),
            KanbanCard(id: "e", title: "Going", status: "running", assignee: "coder"),
            KanbanCard(id: "f", title: "Future", status: "someday"),
        ])
        let sections = KanbanBoard.sections(b)
        XCTAssertEqual(sections.map(\.key), ["todo", "running", "done", "someday"], "empty statuses left out; an unknown one still shows")
        XCTAssertEqual(sections[0].tasks.map(\.id), ["b", "a"], "most important first")
        XCTAssertEqual(sections[2].tasks.map(\.id), ["c", "d"], "finished: newest first")
        XCTAssertEqual(KanbanBoard.sections(b, includeEmpty: true).count, 7, "columns show every status")
        XCTAssertEqual(KanbanBoard.sections(b, assignee: "coder").flatMap(\.tasks).map(\.id), ["a", "e"])
        XCTAssertEqual(KanbanBoard.sections(b, assignee: "").flatMap(\.tasks).map(\.id), ["c", "d", "f"], "nobody's tasks")
    }

    func testOnlyMovesHermesAllows() {
        let b = board([])
        let running = KanbanCard(id: "r", title: "x", status: "running")
        XCTAssertEqual(KanbanBoard.moves(for: running, in: b), ["ready", "blocked", "done", "archived"])
        let archived = KanbanCard(id: "z", title: "x", status: "archived")
        XCTAssertEqual(KanbanBoard.moves(for: archived, in: b), ["triage", "todo", "ready"])
        XCTAssertEqual(KanbanBoard.moveTitle("todo", from: "archived", in: b), "Restore to Todo")
        XCTAssertEqual(KanbanBoard.moveTitle(KanbanBoard.archived, from: "todo", in: b), "Archive")
        XCTAssertEqual(KanbanBoard.moves(for: KanbanCard(id: "n", title: "x", status: "review"), in: b), [], "nothing Hermes didn't say")
    }

    func testWords() {
        XCTAssertEqual(KanbanBoard.duration(30), "under a minute")
        XCTAssertEqual(KanbanBoard.duration(125 * 60), "2 h 5 min")
        XCTAssertEqual(KanbanBoard.duration(3 * 86_400), "3 days")
        XCTAssertNil(KanbanBoard.priorityLabel(0))
        XCTAssertEqual(KanbanBoard.priorityLabel(3), "P3")
        let agents = [ProfileData(profile_id: "coder", name: "Coder", avatar: "terminal")]
        XCTAssertEqual(KanbanBoard.agentName("coder", among: agents), "Coder")
        XCTAssertEqual(KanbanBoard.agentName("gone", among: agents), "gone")
        XCTAssertNil(KanbanBoard.agentName(nil, among: agents))
    }

    @MainActor
    func testEveryActionAgainstTheInstance() async throws {
        let host = try FakeHost()
        host.profiles = [["profile_id": "default", "name": "Default", "avatar": "sparkles"],
                         ["profile_id": "coder", "name": "Coder", "avatar": "terminal"]]
        host.kanbanTasks = [["id": "t_old", "title": "Research", "status": "running", "assignee": "default",
                             "running_since": 1_794_700_000.0, "created_at": 1_794_600_000.0]]
        try await host.start()
        defer { host.stop() }
        let store = InMemoryCredentialStore()
        try SavedHost(instanceId: host.instanceId, instanceName: host.instanceName, deviceId: "dev_1",
                      deviceToken: host.acceptedDeviceToken, endpoints: [host.endpoint],
                      enabledProfileIds: ["default"], activeProfileId: "default").save(to: store)
        let gateway = GatewayClient(keychain: store, requireTLS: false)
        await gateway.resumeSavedSession()

        var b = try await gateway.kanbanBoard()
        XCTAssertEqual(b.tasks.map(\.title), ["Research"])
        XCTAssertEqual(b.tasks.first?.running_since, 1_794_700_000)

        let made = try await gateway.createTask(on: b.board, title: "Write it up", body: "Two pages", assignee: "coder", priority: 2)
        XCTAssertEqual(made.status, "todo")
        XCTAssertEqual(made.assignee, "coder")
        try await gateway.editTask(made.id, on: b.board, title: "Write it", body: "One page", priority: 3)
        try await gateway.commentOnTask(made.id, on: b.board, "Use the new numbers")
        let unassigned = try await gateway.assignTask(made.id, on: b.board, to: nil)
        XCTAssertNil(unassigned.assignee, "nobody")
        let sent = host.received.last { $0["type"] as? String == "kanban.assign" }?["data"] as? [String: Any]
        XCTAssertTrue(sent?.keys.contains("assignee") == true, "unassigning says so (null), not silence")
        let linked = try await gateway.linkTask(made.id, on: b.board, waitsOn: "t_old")
        XCTAssertEqual(linked.waits_on, 1)

        let detail = try await gateway.kanbanTask(made.id, board: b.board)
        XCTAssertEqual(detail.task.title, "Write it")
        XCTAssertEqual(detail.task.priority, 3)
        XCTAssertEqual(detail.comments.map(\.body), ["Use the new numbers"])
        XCTAssertEqual(detail.runs.first?.summary, "Did the thing")

        do {
            _ = try await gateway.moveTask(made.id, on: b.board, to: "done")
            XCTFail("Hermes doesn't allow todo → done")
        } catch let error as HostError {
            XCTAssertEqual(error.code, "MOVE_REFUSED")
            XCTAssertEqual(error.localizedDescription, "It waits on tasks that aren't done", "Hermes' reason is shown")
        }
        try await gateway.moveTask(made.id, on: b.board, to: "ready")
        let done = try await gateway.moveTask(made.id, on: b.board, to: "done", note: "Sent it")
        XCTAssertEqual(done.status, "done")
        let note = host.received.last { $0["type"] as? String == "kanban.move" }?["data"] as? [String: Any]
        XCTAssertEqual(note?["note"] as? String, "Sent it")

        let stopped = try await gateway.stopTask("t_old", on: b.board)
        XCTAssertEqual(stopped.status, "blocked")
        try await gateway.moveTask(made.id, on: b.board, to: KanbanBoard.archived)
        b = try await gateway.kanbanBoard()
        XCTAssertEqual(b.tasks.map(\.id), ["t_old"], "archived ones are hidden")
        b = try await gateway.kanbanBoard(archived: true)
        XCTAssertEqual(b.tasks.count, 2)
    }

    @MainActor
    func testChangesElsewhereAreHeard() async throws {
        let host = try FakeHost()
        host.profiles = [["profile_id": "default", "name": "Default", "avatar": "sparkles"]]
        try await host.start()
        defer { host.stop() }
        let store = InMemoryCredentialStore()
        try SavedHost(instanceId: host.instanceId, instanceName: host.instanceName, deviceId: "dev_1",
                      deviceToken: host.acceptedDeviceToken, endpoints: [host.endpoint],
                      enabledProfileIds: ["default"], activeProfileId: "default").save(to: store)
        let gateway = GatewayClient(keychain: store, requireTLS: false)
        await gateway.resumeSavedSession()
        let before = gateway.kanbanChanges
        host.sendKanbanChanged(["t_9"])
        for _ in 0..<50 where gateway.kanbanChanges == before {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(gateway.kanbanChanges, before + 1)
        XCTAssertEqual(gateway.lastKanbanChange, KanbanChangedData(board: "default", task_ids: ["t_9"]))
    }
}
