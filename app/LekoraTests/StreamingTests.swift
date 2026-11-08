import XCTest
@testable import Lekora

/// Streaming replies (docs/streaming.md): live bubbles and the "thinking…" indicator.
final class StreamingTimelineTests: XCTestCase {
    func testDraftGrowsThenIsReplacedInPlaceBySavedMessage() {
        var timeline = ChatTimeline()
        timeline.applyDraft(draftId: "live-1", profileId: "bruce", text: "Hello")
        timeline.applyDraft(draftId: "live-1", profileId: "bruce", text: "Hello there")
        XCTAssertEqual(timeline.entries.count, 1)
        XCTAssertEqual(timeline.entries[0].status, .streaming)
        XCTAssertEqual(timeline.entries[0].text, "Hello there")

        timeline.applyIncoming(seq: 7, profileId: "bruce", role: "assistant", text: "Hello there, friend.", draftId: "live-1")

        XCTAssertEqual(timeline.entries.count, 1, "replaced, not duplicated")
        XCTAssertEqual(timeline.entries[0].id, "live-1", "same bubble identity: no flicker")
        XCTAssertEqual(timeline.entries[0].seq, 7)
        XCTAssertEqual(timeline.entries[0].status, .sent)
        XCTAssertEqual(timeline.entries[0].text, "Hello there, friend.")
    }

    func testLateDraftAfterSavingIsIgnored() {
        var timeline = ChatTimeline()
        timeline.applyDraft(draftId: "live-1", profileId: "bruce", text: "Hi")
        timeline.applyIncoming(seq: 1, profileId: "bruce", role: "assistant", text: "Hi!", draftId: "live-1")
        timeline.applyDraft(draftId: "live-1", profileId: "bruce", text: "Hi")
        XCTAssertEqual(timeline.entries[0].text, "Hi!")
        XCTAssertEqual(timeline.entries[0].status, .sent)
    }

    func testEmptyDraftRemovesTheBubble() {
        var timeline = ChatTimeline()
        timeline.applyDraft(draftId: "live-1", profileId: "bruce", text: "Hm")
        timeline.applyDraft(draftId: "live-1", profileId: "bruce", text: "")
        XCTAssertTrue(timeline.entries.isEmpty)
        timeline.applyDraft(draftId: "live-2", profileId: "bruce", text: "")
        XCTAssertTrue(timeline.entries.isEmpty, "an empty draft never creates a bubble")
    }

    func testCorrectedMessageUpdatesInPlace() {
        var timeline = ChatTimeline()
        timeline.applyIncoming(seq: 3, profileId: "default", role: "assistant", text: "Version one")
        timeline.applyIncoming(seq: 3, profileId: "default", role: "assistant", text: "Version two")
        XCTAssertEqual(timeline.entries.map(\.text), ["Version two"])
    }

    func testDraftsArePerAgent() {
        var timeline = ChatTimeline()
        timeline.applyDraft(draftId: "a", profileId: "bruce", text: "B")
        timeline.applyDraft(draftId: "b", profileId: "work", text: "W")
        XCTAssertEqual(timeline.entries(for: "bruce").map(\.text), ["B"])
        XCTAssertEqual(timeline.entries(for: "work").map(\.text), ["W"])
    }

    func testReconnectDropsOnlyUnfinishedReplies() {
        var timeline = ChatTimeline()
        timeline.applyIncoming(seq: 1, profileId: "default", role: "assistant", text: "Saved")
        timeline.applyDraft(draftId: "live-1", profileId: "default", text: "Half")
        timeline.dropUnfinishedReplies()
        XCTAssertEqual(timeline.entries.map(\.text), ["Saved"])
    }
}

@MainActor
final class StreamingClientTests: XCTestCase {
    private var host: FakeHost!

    override func setUp() async throws {
        host = try FakeHost()
        host.profiles = [
            ["profile_id": "default", "name": "Default", "avatar": "sparkles"],
            ["profile_id": "bruce", "name": "Bruce", "avatar": "sparkles"],
        ]
        host.history = []
        try await host.start()
    }

    override func tearDown() async throws {
        host.stop()
        host = nil
    }

    private func connected() async -> GatewayClient {
        let gateway = GatewayClient(keychain: InMemoryCredentialStore(), requireTLS: false)
        await gateway.pairAndConnect(pairingToken: host.validPairingToken, instanceId: host.instanceId,
                                     candidateEndpoints: [host.endpoint])
        gateway.chooseProfiles(["default", "bruce"])
        return gateway
    }

    func testStreamedReplyEndsAsOneSavedMessage() async {
        let gateway = await connected()
        host.streamReply(profile: "bruce", words: ["Let", "me", "think", "about", "that."])

        let saved = await waitUntil {
            gateway.timeline.entries(for: "bruce").last?.status == .sent
        }
        XCTAssertTrue(saved)
        let entries = gateway.timeline.entries(for: "bruce")
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].text, "Let me think about that.")
        XCTAssertEqual(entries[0].seq, 1)
        let stopped = await waitUntil { gateway.agentActivity["bruce"] == nil }
        XCTAssertTrue(stopped, "thinking indicator off when the reply is done")
    }

    func testWorkingStatusIsShownPerAgent() async {
        let gateway = await connected()
        host.streamReply(profile: "bruce", words: ["Searching"], status: "Searching the web", seal: false)
        let working = await waitUntil { gateway.agentActivity["bruce"]?.status == "Searching the web" }
        XCTAssertTrue(working)
        XCTAssertNil(gateway.agentActivity["default"], "other agents aren't marked busy")
        XCTAssertEqual(gateway.timeline.entries(for: "bruce").last?.status, .streaming)
    }

    func testIndicatorClearsItselfWhenTheHostGoesQuiet() async {
        let gateway = await connected()
        gateway.activityTimeout = 0.3
        host.streamReply(profile: "bruce", words: ["Hm"], seal: false)
        let on = await waitUntil { gateway.agentActivity["bruce"] != nil }
        XCTAssertTrue(on)
        let off = await waitUntil(timeout: 3) { gateway.agentActivity["bruce"] == nil }
        XCTAssertTrue(off)
    }

    func testReconnectReplacesHalfShownReplyWithTheSavedOne() async throws {
        let gateway = await connected()
        host.streamReply(profile: "bruce", words: ["Half", "a"], seal: false)
        _ = await waitUntil { gateway.timeline.entries(for: "bruce").last?.text == "Half a" }
        gateway.disconnect()
        // While the phone was away the host finished and saved the reply.
        host.history.append((1, "assistant", "Half a sentence, now complete.", "bruce"))

        await gateway.resumeSavedSession()

        let replayed = await waitUntil {
            gateway.timeline.entries(for: "bruce").map(\.text) == ["Half a sentence, now complete."]
        }
        XCTAssertTrue(replayed, "no leftover live bubble next to the saved reply")
        XCTAssertTrue(gateway.agentActivity.isEmpty)
    }
}
