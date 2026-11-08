import XCTest
@testable import Lekora

final class ChatTimelineTests: XCTestCase {
    func testOutgoingThenReplyKeepsChronologicalOrder() {
        var timeline = ChatTimeline()
        timeline.addOutgoing(id: "m1", profileId: "assistant", text: "Hello")
        XCTAssertEqual(timeline.entries.first?.status, .sending)
        timeline.markSent(id: "m1")
        timeline.applyIncoming(seq: 8, profileId: "assistant", role: "assistant", text: "Hi there")

        let entries = timeline.entries(for: "assistant")
        XCTAssertEqual(entries.map(\.text), ["Hello", "Hi there"])
        XCTAssertEqual(entries.map(\.role), [.user, .agent])
        XCTAssertEqual(entries.first?.status, .sent)
    }

    func testReplayedOwnMessageIsMatchedNotDuplicated() {
        var timeline = ChatTimeline()
        timeline.addOutgoing(id: "m1", profileId: "assistant", text: "Hello")
        timeline.markSent(id: "m1")
        // After a reconnect the host replays our message with its seq.
        timeline.applyIncoming(seq: 7, profileId: "assistant", role: "user", text: "Hello")

        XCTAssertEqual(timeline.entries.count, 1)
        XCTAssertEqual(timeline.entries.first?.seq, 7)
        XCTAssertEqual(timeline.entries.first?.id, "m1")
    }

    func testRepeatedSeqIsIgnored() {
        var timeline = ChatTimeline()
        timeline.applyIncoming(seq: 3, profileId: "assistant", role: "assistant", text: "Pong")
        timeline.applyIncoming(seq: 3, profileId: "assistant", role: "assistant", text: "Pong")
        XCTAssertEqual(timeline.entries.count, 1)
    }

    func testUserMessageFromAnotherDeviceIsShown() {
        var timeline = ChatTimeline()
        timeline.applyIncoming(seq: 4, profileId: "assistant", role: "user", text: "Sent from iPad")
        XCTAssertEqual(timeline.entries.first?.role, .user)
        XCTAssertEqual(timeline.entries.first?.status, .sent)
    }

    func testFailureIsMarkedOnTheRightMessage() {
        var timeline = ChatTimeline()
        timeline.addOutgoing(id: "m1", profileId: "assistant", text: "One")
        timeline.addOutgoing(id: "m2", profileId: "assistant", text: "Two")
        XCTAssertTrue(timeline.markFailed(id: "m2", reason: "Unknown profile"))
        XCTAssertFalse(timeline.markFailed(id: "nope", reason: "x"))

        XCTAssertEqual(timeline.entries[0].status, .sending)
        XCTAssertEqual(timeline.entries[1].status, .failed("Unknown profile"))
    }

    func testEntriesAreSeparatedByProfile() {
        var timeline = ChatTimeline()
        timeline.applyIncoming(seq: 1, profileId: "assistant", role: "assistant", text: "A")
        timeline.applyIncoming(seq: 2, profileId: "coder", role: "assistant", text: "B")
        XCTAssertEqual(timeline.entries(for: "coder").map(\.text), ["B"])
    }

    func testChatSendEnvelopeWireFormat() throws {
        let envelope = GatewayClient.makeChatSendEnvelope(text: "What's on my calendar?", instanceId: "inst_1", profileId: "assistant")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope)) as? [String: Any])

        XCTAssertEqual(json["type"] as? String, "chat.send")
        XCTAssertEqual(json["v"] as? Int, 1)
        XCTAssertEqual(json["instance_id"] as? String, "inst_1")
        XCTAssertEqual(json["profile_id"] as? String, "assistant")
        XCTAssertEqual((json["data"] as? [String: Any])?["text"] as? String, "What's on my calendar?")
        XCTAssertFalse((json["id"] as? String ?? "").isEmpty)
    }

    @MainActor
    func testGatewayAppliesHostFrames() throws {
        let gateway = GatewayClient()
        let reply = """
        {"v":1,"id":"e1","type":"chat.message","instance_id":"inst_1","profile_id":"assistant",
         "ts":"2026-11-07T21:05:01Z","data":{"seq":12,"role":"assistant","text":"Pong"}}
        """
        gateway.handleIncoming(Data(reply.utf8))
        XCTAssertEqual(gateway.currentSeq, 12)
        XCTAssertEqual(gateway.timeline.entries.map(\.text), ["Pong"])

        // Unknown frame types are ignored rather than breaking the loop.
        gateway.handleIncoming(Data(#"{"v":1,"id":"x","type":"something.new","instance_id":"inst_1","ts":"t","data":{}}"#.utf8))
        XCTAssertEqual(gateway.timeline.entries.count, 1)
    }
}
