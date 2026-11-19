import XCTest
@testable import Lekora

/// Helpers as a live tree in the chat (docs/delegation.md).
@MainActor
final class HelpersTests: XCTestCase {
    private var host: FakeHost!

    override func setUp() async throws {
        host = try FakeHost()
        host.profiles = [
            ["profile_id": "default", "name": "Home", "avatar": "sparkles"],
            ["profile_id": "researcher", "name": "Researcher", "avatar": "sparkles"],
        ]
        host.history = [(1, "assistant", "Hi", "default")]
        try await host.start()
    }

    override func tearDown() async throws {
        host.stop()
        host = nil
    }

    private func connected() async throws -> GatewayClient {
        let store = InMemoryCredentialStore()
        try SavedHost(instanceId: host.instanceId, instanceName: host.instanceName, deviceId: "dev_1",
                      deviceToken: host.acceptedDeviceToken, endpoints: [host.endpoint],
                      enabledProfileIds: ["default", "researcher"], activeProfileId: "default").save(to: store)
        let gateway = GatewayClient(keychain: store, requireTLS: false)
        await gateway.resumeSavedSession()
        _ = await waitUntil { !gateway.timeline.entries.isEmpty }
        return gateway
    }

    private func helper(_ id: String, _ status: String = "working", parent: String? = nil, agent: String? = nil,
                        steps: Int = 0, doing: String? = nil, summary: String? = nil) -> [String: Any] {
        var h: [String: Any] = ["id": id, "goal": "Task \(id)", "status": status, "steps": steps,
                                "started_at": "2026-11-19T08:00:00Z"]
        if let parent { h["parent"] = parent }
        if let agent { h["agent"] = agent }
        if let doing { h["doing"] = doing }
        if let summary { h["summary"] = summary; h["ended_at"] = "2026-11-19T08:01:05Z" }
        return h
    }

    private func card(seq: Int, rev: Int, _ helpers: [[String: Any]], status: String = "working") -> [String: Any] {
        ["seq": seq, "role": "helpers", "text": "Using helpers", "rev": rev,
         "delegation": ["status": status, "helpers": helpers]]
    }

    func testCardArrivesAndUpdatesInPlace() async throws {
        let gateway = try await connected()
        host.pushMessage(card(seq: 2, rev: 20, [helper("sa-0")]), profile: "default")
        let arrived = await waitUntil { gateway.timeline.entries.contains { $0.delegation != nil } }
        XCTAssertTrue(arrived)
        let entry = try XCTUnwrap(gateway.timeline.entries.first { $0.seq == 2 })
        XCTAssertEqual(entry.role, .helpers)

        host.pushMessage(card(seq: 2, rev: 21, [helper("sa-0", steps: 4, doing: "Web search"),
                                                helper("sa-1", agent: "researcher")]), profile: "default")
        let updated = await waitUntil { gateway.timeline.entries.first { $0.seq == 2 }?.delegation?.helpers.count == 2 }
        XCTAssertTrue(updated)
        let tree = try XCTUnwrap(gateway.timeline.entries.first { $0.seq == 2 }?.delegation)
        XCTAssertEqual(tree.helpers[0].doing, "Web search")
        XCTAssertEqual(tree.helpers[1].agent, "researcher")
        XCTAssertEqual(gateway.agentName("researcher"), "Researcher")
        XCTAssertEqual(gateway.timeline.entries.filter { $0.seq == 2 }.count, 1)
    }

    func testStopOneAndStopAllGoToTheHost() async throws {
        let gateway = try await connected()
        host.helpersStoppable[2] = ["sa-0", "sa-1"]
        let one = try await gateway.stopHelpers(profileId: "default", seq: 2, helperId: "sa-1")
        XCTAssertEqual(one, ["sa-1"])
        let all = try await gateway.stopHelpers(profileId: "default", seq: 2, helperId: nil)
        XCTAssertEqual(all, ["sa-0", "sa-1"])
        let sent = host.received(type: "delegation.stop").compactMap { $0["data"] as? [String: Any] }
        XCTAssertEqual(sent.first?["helper_id"] as? String, "sa-1")
        XCTAssertEqual(sent.first?["seq"] as? Int, 2)
    }

    func testStoppingFinishedHelpersSaysSo() async throws {
        let gateway = try await connected()
        do {
            try await gateway.stopHelpers(profileId: "default", seq: 9, helperId: nil)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("already finished"))
        }
    }

    func testTreeOrderPutsEachHelpersOwnHelpersUnderIt() {
        let tree = HelpersTree(status: "working", helpers: [
            .init(id: "a", goal: "A", status: "working"),
            .init(id: "b", goal: "B", status: "done"),
            .init(id: "a1", parent: "a", goal: "A1", status: "working"),
            .init(id: "orphan", parent: "gone", goal: "O", status: "done"),
        ])
        XCTAssertEqual(tree.rows.map(\.id), ["a", "a1", "b", "orphan"])
        XCTAssertEqual(tree.rows.map(\.depth), [0, 1, 0, 0])
        XCTAssertEqual(tree.workingCount, 2)
    }

    func testWords() throws {
        let start = try Date("2026-11-19T08:00:00Z", strategy: .iso8601)
        let working = HelpersTree.Helper(id: "a", goal: "g", status: "working", doing: "Web search", steps: 3,
                                         started_at: "2026-11-19T08:00:00Z")
        XCTAssertEqual(LKHelpersText.detail(working, now: start + 83), "Web search · 3 steps · 1m 23s")
        let done = HelpersTree.Helper(id: "b", goal: "g", status: "done", steps: 1, started_at: "2026-11-19T08:00:00Z",
                                      ended_at: "2026-11-19T08:00:09Z")
        XCTAssertEqual(LKHelpersText.detail(done, now: start + 999), "Done · 1 step · 9s")
        XCTAssertEqual(LKHelpersText.summary(HelpersTree(status: "working", helpers: [working, done])), "1 of 2 working")
        var failed = done
        failed.status = "failed"
        XCTAssertEqual(LKHelpersText.summary(HelpersTree(status: "done", helpers: [done, failed])),
                       "2 helpers finished, 1 didn't make it")
    }

    func testCardSurvivesTheCacheAndDecodesFromTheWire() throws {
        let json = #"{"seq":5,"role":"helpers","text":"Used 1 helper","rev":50,"delegation":{"status":"done","helpers":[{"id":"sa-0-ab","goal":"Find flights","agent":"researcher","status":"done","steps":4,"started_at":"2026-11-19T08:00:00Z","ended_at":"2026-11-19T08:01:00Z","summary":"Two found"}]}}"#
        let message = try JSONDecoder().decode(ChatMessageData.self, from: Data(json.utf8))
        XCTAssertEqual(message.delegation?.helpers.first?.summary, "Two found")
        var timeline = ChatTimeline()
        timeline.applyPage(profileId: "default", messages: [message], hasMore: false)
        let restored = try JSONDecoder().decode([ChatEntry].self, from: JSONEncoder().encode(timeline.entries))
        XCTAssertEqual(restored.first?.role, .helpers)
        XCTAssertEqual(restored.first?.delegation, message.delegation)
    }
}
