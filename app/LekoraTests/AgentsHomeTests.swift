import XCTest
@testable import Lekora

/// The agents list, avatars, previews and times (docs/agents-home.md).
@MainActor
final class AgentsHomeTests: XCTestCase {
    // MARK: - Avatars

    func testAvatarIsStableAndSpreadsAcrossAgents() {
        XCTAssertEqual(LKAgentLook(id: "bruce"), LKAgentLook(id: "bruce"), "same on every launch and phone")
        let ids = ["default", "ashlyn", "brenda", "bruce", "carl", "diane", "work", "coder"]
        let looks = ids.map { LKAgentLook(id: $0) }
        XCTAssertGreaterThan(Set(looks.map(\.paletteIndex)).count, 3, "colours vary")
        XCTAssertGreaterThan(Set(looks.map { "\($0.headShape)" }).count, 2, "head shapes vary")
        XCTAssertGreaterThan(Set(looks.map { "\($0.eyeStyle)" }).count, 1, "eyes vary")
    }

    func testYourAgentsNeverShareColours() {
        let ids = ["default", "ashlyn", "brenda", "bruce", "carl", "diane"]
        let palettes = LKAgentLook.assignPalettes(ids)
        XCTAssertEqual(Set(palettes.values).count, ids.count)
        XCTAssertEqual(palettes, LKAgentLook.assignPalettes(ids.reversed()), "same on every phone")
    }

    func testBotsBlinkGlanceAndBob() {
        let look = LKAgentLook(id: "bruce")
        let frames = stride(from: 0.0, to: 20.0, by: 0.02).map { LKAgentMotion(look: look, working: false, time: $0) }
        XCTAssertTrue(frames.contains { $0.eyeOpen < 0.3 }, "blinks")
        XCTAssertGreaterThan(frames.filter { $0.eyeOpen > 0.99 }.count, frames.count * 9 / 10, "eyes mostly open")
        XCTAssertTrue(frames.contains { $0.look < -0.9 } && frames.contains { $0.look > 0.9 }, "looks left and right")
        XCTAssertTrue(frames.allSatisfy { abs($0.bob) <= 0.05 }, "a gentle bob")
        let still = LKAgentMotion(look: look, working: false, time: 0)
        XCTAssertEqual(still.eyeOpen, LKAgentMotion(look: look, working: false, time: 0).eyeOpen, "pure")
    }

    func testStableHashIsFNV1a() {
        // Known FNV-1a 64 values: the avatar must not change between app versions.
        XCTAssertEqual(LKAgentLook.stableHash(""), 0xcbf29ce484222325)
        XCTAssertEqual(LKAgentLook.stableHash("a"), 0xaf63dc4c8601ec8c)
    }

    // MARK: - Previews and times

    func testPreviewDropsMarkdownAndJoinsLines() {
        XCTAssertEqual(LKChatText.preview("**Ramen512** — 1420 Cypress Creek Rd\n\n- Open late\n- [Menu](https://x.y)"),
                       "Ramen512 — 1420 Cypress Creek Rd Open late Menu")
        XCTAssertEqual(LKChatText.preview("## Plan\n1. `ls` first"), "Plan: ls first")
        XCTAssertEqual(LKChatText.preview("## Report\nThe Q3 draft is ready."), "Report: The Q3 draft is ready.")
    }

    func testListTimeLabels() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 16, minute: 45))!
        func ago(days: Int, hour: Int = 9) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 11, day: 8 - days, hour: hour))!
        }
        XCTAssertEqual(LKTime.listLabel(ago(days: 1), now: now, calendar: calendar), "Yesterday")
        XCTAssertFalse(LKTime.listLabel(ago(days: 0), now: now, calendar: calendar).contains("day"), "today shows a time")
        XCTAssertEqual(LKTime.listLabel(ago(days: 3), now: now, calendar: calendar),
                       ago(days: 3).formatted(.dateTime.weekday(.wide)))
        XCTAssertEqual(LKTime.listLabel(ago(days: 20), now: now, calendar: calendar),
                       ago(days: 20).formatted(date: .abbreviated, time: .omitted))
        XCTAssertTrue(LKTime.separatorLabel(ago(days: 0), now: now, calendar: calendar).hasPrefix("Today "))
        XCTAssertTrue(LKTime.separatorLabel(ago(days: 1), now: now, calendar: calendar).hasPrefix("Yesterday "))
    }

    func testTimeLineAfterQuarterHourGaps() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func entry(_ id: String, minutes: Double?) -> ChatEntry {
            ChatEntry(id: id, profileId: "p", role: .agent, text: id, date: minutes.map { start.addingTimeInterval($0 * 60) })
        }
        let entries = [entry("a", minutes: 0), entry("b", minutes: 5), entry("c", minutes: 30),
                       entry("old", minutes: nil), entry("d", minutes: 44)]
        XCTAssertEqual(LKTime.separatorIds(for: entries), ["a", "c"])
    }

    func testWorkingLine() {
        XCTAssertEqual(AgentsHomeView.workingLine("is searching the web for ramen"), "Searching the web for ramen")
        XCTAssertEqual(AgentsHomeView.workingLine(nil), "Thinking…")
        XCTAssertEqual(AgentsHomeView.workingLine("Compressing context"), "Compressing context")
    }

    // MARK: - With a host

    private var host: FakeHost!

    override func setUp() async throws {
        host = try FakeHost()
        host.profiles = [
            ["profile_id": "default", "name": "Home", "avatar": "sparkles"],
            ["profile_id": "bruce", "name": "Bruce", "avatar": "sparkles"],
            ["profile_id": "carl", "name": "Carl", "avatar": "sparkles"],
        ]
        host.history = [
            (1, "assistant", "Bruce first", "bruce"),
            (2, "assistant", "Home later", "default"),
        ]
        try await host.start()
    }

    override func tearDown() async throws {
        host.stop()
        host = nil
    }

    private func connected(active: String = "default") async throws -> GatewayClient {
        let store = InMemoryCredentialStore()
        try SavedHost(instanceId: host.instanceId, instanceName: host.instanceName, deviceId: "dev_1",
                      deviceToken: host.acceptedDeviceToken, endpoints: [host.endpoint],
                      enabledProfileIds: ["default", "bruce", "carl"], activeProfileId: active).save(to: store)
        let gateway = GatewayClient(keychain: store, requireTLS: false)
        await gateway.resumeSavedSession()
        _ = await waitUntil { gateway.timeline.entries.count == 2 }
        return gateway
    }

    func testAgentsAreListedMostRecentFirst() async throws {
        let gateway = try await connected()
        XCTAssertEqual(gateway.agentsByRecency.map(\.profile_id), ["default", "bruce", "carl"],
                       "no messages yet: last, in the host's order")
        host.streamReply(profile: "carl", words: ["Carl", "here."])
        _ = await waitUntil { gateway.timeline.entries.count == 3 }
        XCTAssertEqual(gateway.agentsByRecency.map(\.profile_id), ["carl", "default", "bruce"])
    }

    func testBackButtonCountsOtherAgentsWithUnreadReplies() async throws {
        let gateway = try await connected(active: "default")
        gateway.setChatVisible(true)
        XCTAssertEqual(gateway.otherAgentsWithUnread, 1, "Bruce")
        host.streamReply(profile: "carl", words: ["Hi"])
        _ = await waitUntil { gateway.otherAgentsWithUnread == 2 }
        XCTAssertEqual(gateway.otherAgentsWithUnread, 2)
        gateway.switchToProfile("bruce")
        XCTAssertEqual(gateway.otherAgentsWithUnread, 1, "Carl still waiting; Default is read")
    }

    func testMessageTimesAreKept() async throws {
        host.messageTime = "2026-11-08T22:42:05Z"
        let gateway = try await connected()
        let expected = try Date("2026-11-08T22:42:05Z", strategy: .iso8601)
        XCTAssertEqual(gateway.timeline.entries.first?.date, expected)

        let cached = try JSONDecoder().decode(ChatEntry.self, from: JSONEncoder().encode(gateway.timeline.entries[0]))
        XCTAssertEqual(cached.date, expected, "kept in the phone's cache")
        let fromOldCache = try JSONDecoder().decode(ChatEntry.self, from: Data(
            #"{"id":"seq-1","profileId":"p","role":{"agent":{}},"text":"x","seq":1,"status":{"sent":{}}}"#.utf8))
        XCTAssertNil(fromOldCache.date, "caches from before times still load")
    }
}
