import XCTest
@testable import Lekora

/// Chat history kept on the phone, older pages, and unread dots (docs/chat-history.md).
@MainActor
final class ChatHistoryTests: XCTestCase {
    private var host: FakeHost!
    private var cacheDir: URL!

    override func setUp() async throws {
        host = try FakeHost()
        host.profiles = [
            ["profile_id": "default", "name": "Home", "avatar": "sparkles"],
            ["profile_id": "bruce", "name": "Bruce", "avatar": "sparkles"],
        ]
        host.history = [
            (1, "user", "Plan my weekend", "default"),
            (2, "assistant", "How about a hike?", "default"),
            (3, "assistant", "Bruce here, the report is done.", "bruce"),
        ]
        try await host.start()
        cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("lekora-cache-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        host.stop()
        host = nil
        try? FileManager.default.removeItem(at: cacheDir)
    }

    private var cacheStore: ChatCacheStore { ChatCacheStore(directory: cacheDir) }

    private func savedStore(active: String = "default") throws -> InMemoryCredentialStore {
        let store = InMemoryCredentialStore()
        try SavedHost(instanceId: host.instanceId, instanceName: host.instanceName, deviceId: "dev_1",
                      deviceToken: host.acceptedDeviceToken, endpoints: [host.endpoint],
                      enabledProfileIds: ["default", "bruce"], activeProfileId: active).save(to: store)
        return store
    }

    private func connected(_ store: InMemoryCredentialStore, cache: Bool = true) async -> GatewayClient {
        let gateway = GatewayClient(keychain: store, requireTLS: false, cacheStore: cache ? cacheStore : nil)
        await gateway.resumeSavedSession()
        return gateway
    }

    private func lastHello() -> [String: Any] {
        host.received(type: "hello").last?["data"] as? [String: Any] ?? [:]
    }

    private func reads() -> [(String, Int)] {
        host.received(type: "chat.read").compactMap { env in
            guard let profile = env["profile_id"] as? String,
                  let seq = (env["data"] as? [String: Any])?["seq"] as? Int else { return nil }
            return (profile, seq)
        }
    }

    // MARK: - Kept on the phone

    func testChatsShowOnLaunchBeforeConnectingAndOnlyChangesAreFetched() async throws {
        let store = try savedStore()
        let first = await connected(store)
        _ = await waitUntil { first.timeline.entries.count == 3 }
        first.saveCacheNow()
        first.disconnect()

        let relaunched = GatewayClient(keychain: store, requireTLS: false, cacheStore: cacheStore)
        XCTAssertEqual(relaunched.timeline.entries(for: "default").map(\.text),
                       ["Plan my weekend", "How about a hike?"], "shown before the host answers")
        XCTAssertTrue(relaunched.hasCachedChats)
        XCTAssertEqual(relaunched.activeProfile?.name, "Home")

        await relaunched.resumeSavedSession()
        XCTAssertEqual(lastHello()["since_rev"] as? Int, 30, "asks only for what changed")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(relaunched.timeline.entries.count, 3, "nothing duplicated")
    }

    func testMessagesCachedWithoutTimesGetThemOnceTheHostSendsTimes() async throws {
        host.messageTime = nil  // a host from before message times
        let store = try savedStore()
        let first = await connected(store)
        _ = await waitUntil { first.timeline.entries.count == 3 }
        await first.sendMessage("Mine")  // sent from here: keeps the phone's own time
        _ = await waitUntil { first.timeline.entries.count == 5 }
        first.saveCacheNow()
        first.disconnect()

        let offline = GatewayClient(keychain: store, requireTLS: false, cacheStore: cacheStore)
        XCTAssertNotNil(offline.timeline.entries.first { $0.text == "Mine" }?.date, "own times survive a relaunch")

        host.messageTime = "2026-11-08T12:00:00Z"  // the host is updated
        let relaunched = await connected(store)
        XCTAssertEqual(lastHello()["since_rev"] as? Int, 50, "only what changed: nothing is thrown away")
        let dated = await waitUntil { relaunched.timeline.entries.allSatisfy { $0.date != nil } }
        XCTAssertTrue(dated, "times filled in")
        XCTAssertEqual(relaunched.timeline.entries.count, 5)
    }

    func testCorrectionMadeWhileAwayArrives() async throws {
        let store = try savedStore()
        let first = await connected(store)
        _ = await waitUntil { first.timeline.entries.count == 3 }
        first.saveCacheNow()
        first.disconnect()

        host.correct(seq: 2, text: "How about a hike? Bring water.")
        let relaunched = await connected(store)
        let updated = await waitUntil {
            relaunched.timeline.entries.first { $0.seq == 2 }?.text == "How about a hike? Bring water."
        }
        XCTAssertTrue(updated)
        XCTAssertEqual(relaunched.timeline.entries.count, 3)
    }

    func testOwnMessageGetsItsNumberAndIsKept() async throws {
        let store = try savedStore()
        let gateway = await connected(store)
        _ = await waitUntil { gateway.timeline.entries.count == 3 }
        await gateway.sendMessage("Thanks!")
        let numbered = await waitUntil { gateway.timeline.entries.first { $0.text == "Thanks!" }?.seq == 4 }
        XCTAssertTrue(numbered, "matched by client_id")
        XCTAssertEqual(gateway.timeline.entries.filter { $0.text == "Thanks!" }.count, 1)
        gateway.saveCacheNow()
        XCTAssertEqual(cacheStore.load(instanceId: host.instanceId)?.entries.last?.text, "default says: Thanks!")
    }

    func testForgetHostDeletesTheCache() async throws {
        let gateway = await connected(try savedStore())
        _ = await waitUntil { gateway.timeline.entries.count == 3 }
        gateway.saveCacheNow()
        XCTAssertNotNil(cacheStore.load(instanceId: host.instanceId))
        await gateway.forgetHost()
        XCTAssertNil(cacheStore.load(instanceId: host.instanceId))
    }

    // MARK: - Recent replay and older pages

    func testNewPhoneGetsRecentMessagesThenOlderOnesWhenScrollingUp() async throws {
        host.history = (1...7).map { ($0, $0 % 2 == 0 ? "assistant" : "user", "m\($0)", "default") }
        host.recentLimit = 3
        let gateway = await connected(try savedStore(), cache: false)
        XCTAssertEqual(lastHello()["since_rev"] as? Int, 0)
        _ = await waitUntil { gateway.timeline.entries.count == 3 }
        XCTAssertEqual(gateway.timeline.entries.map(\.text), ["m5", "m6", "m7"])
        XCTAssertTrue(gateway.canLoadOlder("default"))

        await gateway.loadOlderMessages("default")
        XCTAssertEqual(gateway.timeline.entries.map(\.text), (1...7).map { "m\($0)" }, "inserted above, in order")
        XCTAssertFalse(gateway.canLoadOlder("default"), "whole history is here")
        let fetch = try XCTUnwrap(host.received(type: "history.fetch").last)
        XCTAssertEqual(fetch["profile_id"] as? String, "default")
        XCTAssertEqual((fetch["data"] as? [String: Any])?["before_seq"] as? Int, 5)
    }

    func testRecentReplayReplacesWhatWasCached() {
        var timeline = ChatTimeline()
        timeline.applyIncoming(seq: 1, profileId: "default", role: "assistant", text: "old")
        timeline.addOutgoing(id: "local", profileId: "default", text: "unsent")
        timeline.replaceSavedWithRecent()
        XCTAssertEqual(timeline.entries.map(\.text), ["unsent"])
    }

    // MARK: - Unread dots

    func testOtherAgentsRepliesShowAsUnreadAndClearWhenOpened() async throws {
        let gateway = await connected(try savedStore())
        _ = await waitUntil { gateway.timeline.entries.count == 3 }
        gateway.setChatVisible(true)

        XCTAssertFalse(gateway.hasUnread("default"), "the open chat is read")
        XCTAssertTrue(gateway.hasUnread("bruce"))
        XCTAssertTrue(gateway.otherAgentsHaveUnread)
        _ = await waitUntil { self.reads().contains { $0 == ("default", 2) } }

        gateway.switchToProfile("bruce")
        XCTAssertFalse(gateway.hasUnread("bruce"))
        XCTAssertFalse(gateway.otherAgentsHaveUnread)
        let told = await waitUntil { self.reads().contains { $0 == ("bruce", 3) } }
        XCTAssertTrue(told, "the host (and so the other phones) hear about it")
    }

    func testNothingIsMarkedReadWhileTheChatIsNotOnScreen() async throws {
        let gateway = await connected(try savedStore())
        _ = await waitUntil { gateway.timeline.entries.count == 3 }
        XCTAssertTrue(gateway.hasUnread("default"))
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(reads().isEmpty)
    }

    func testReadingOnAnotherPhoneClearsTheDot() async throws {
        let gateway = await connected(try savedStore())
        _ = await waitUntil { gateway.timeline.entries.count == 3 }
        XCTAssertTrue(gateway.hasUnread("bruce"))
        host.readElsewhere(profile: "bruce", seq: 3)
        let cleared = await waitUntil { !gateway.hasUnread("bruce") }
        XCTAssertTrue(cleared)
    }

    func testHostsReadMarkersAreUsedOnConnect() async throws {
        host.readMarkers = ["bruce": 3]
        let gateway = await connected(try savedStore())
        _ = await waitUntil { gateway.timeline.entries.count == 3 }
        XCTAssertFalse(gateway.hasUnread("bruce"))
    }

    func testReplyArrivingInTheOpenChatIsReadStraightAway() async throws {
        let gateway = await connected(try savedStore(active: "bruce"))
        _ = await waitUntil { gateway.timeline.entries.count == 3 }
        gateway.setChatVisible(true)
        host.streamReply(profile: "bruce", words: ["All", "done."])
        _ = await waitUntil { gateway.timeline.entries.count == 4 }
        XCTAssertFalse(gateway.hasUnread("bruce"))
        let told = await waitUntil { self.reads().contains { $0 == ("bruce", 4) } }
        XCTAssertTrue(told)
    }

    func testOlderHostShowsNoDots() async throws {
        host.legacyHello = true
        let gateway = await connected(try savedStore())
        _ = await waitUntil { gateway.timeline.entries.count == 3 }
        XCTAssertFalse(gateway.hostTracksRead)
        XCTAssertFalse(gateway.hasUnread("bruce"))
    }

    // MARK: - Timeline rules

    func testCorrectionToAMessageOlderThanWhatsHeldIsSkippedUntilItsPageLoads() {
        var timeline = ChatTimeline()
        timeline.applyIncoming(seq: 10, profileId: "default", role: "assistant", text: "ten")
        timeline.applyIncoming(seq: 4, profileId: "default", role: "assistant", text: "four, corrected")
        XCTAssertEqual(timeline.entries.map(\.seq), [10], "no gap left in the history")
        timeline.applyPage(profileId: "default", messages: [ChatMessageData(seq: 4, role: "assistant", text: "four, corrected")],
                           hasMore: false)
        XCTAssertEqual(timeline.entries.map(\.seq), [4, 10])
        XCTAssertTrue(timeline.completeProfiles.contains("default"))
    }

    func testCacheKeepsSavedMessagesOnlyAndTrimsLongChats() {
        var timeline = ChatTimeline()
        for seq in 1...5 { timeline.applyIncoming(seq: seq, profileId: "default", role: "assistant", text: "m\(seq)") }
        timeline.applyPage(profileId: "default", messages: [], hasMore: false)
        timeline.applyDraft(draftId: "live-1", profileId: "default", text: "writing…")
        timeline.addOutgoing(id: "local", profileId: "default", text: "unsent")
        let kept = timeline.cacheSnapshot(perProfile: 3)
        XCTAssertEqual(kept.entries.map(\.text), ["m3", "m4", "m5"])
        XCTAssertFalse(kept.completeProfiles.contains("default"), "older ones now load from the host")
    }
}
