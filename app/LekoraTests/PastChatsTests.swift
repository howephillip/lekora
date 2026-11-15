import XCTest
@testable import Lekora

/// Past chats (docs/chats.md).
final class PastChatsTests: XCTestCase {
    func testMessagesKnowTheirConversation() {
        var timeline = ChatTimeline()
        timeline.applyIncoming(seq: 1, profileId: "a", role: "user", text: "old", session: "s_old")
        timeline.applyIncoming(seq: 2, profileId: "a", role: "assistant", text: "new", session: "s_now")
        XCTAssertEqual(timeline.entries.map(\.session), ["s_old", "s_now"])
        timeline.applyIncoming(seq: 1, profileId: "a", role: "user", text: "old", session: "s_older")
        XCTAssertEqual(timeline.entries.first?.session, "s_older", "a later answer from the instance wins")
    }

    @MainActor
    func testListReadAndContinue() async throws {
        let host = try FakeHost()
        host.profiles = [["profile_id": "default", "name": "Default", "avatar": "sparkles"]]
        host.chats = [["session_id": "s_now", "title": "Tickets", "messages": 3, "current": true, "started_at": 1_794_700_000.0],
                      ["session_id": "s_old", "preview": "Hey", "messages": 1, "current": false, "started_at": 1_794_600_000.0]]
        host.chatHistory = ["s_old": [["seq": 99, "role": "user", "text": "Hey", "rev": 1, "session": "s_old"]]]
        try await host.start()
        defer { host.stop() }
        let store = InMemoryCredentialStore()
        try SavedHost(instanceId: host.instanceId, instanceName: host.instanceName, deviceId: "dev_1",
                      deviceToken: host.acceptedDeviceToken, endpoints: [host.endpoint],
                      enabledProfileIds: ["default"], activeProfileId: "default").save(to: store)
        let gateway = GatewayClient(keychain: store, requireTLS: false)
        await gateway.resumeSavedSession()

        await gateway.loadChats(for: "default")
        XCTAssertEqual(gateway.currentChat["default"], "s_now")
        XCTAssertEqual(gateway.pastChats["default"]?.map(\.name), ["Tickets", "Hey"], "untitled chats show their first words")
        let old = try await gateway.chatHistory("s_old", in: "default")
        XCTAssertEqual(old.first?.text, "Hey")
        try await gateway.resumeChat("s_old", in: "default")
        XCTAssertEqual(gateway.currentChat["default"], "s_old", "the continued chat is the chat again")
        XCTAssertTrue(gateway.timeline.entries(for: "default").contains { $0.text == "Hey" }, "its messages come into the chat")
    }
}

final class NewChatFollowsTests: XCTestCase {
    @MainActor
    func testANewChatNoticeMovesTheChatOn() async throws {
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
        host.pushMessage(["seq": 50, "role": "system", "text": "New session started.", "rev": 500, "session": "s_fresh"], profile: "default")
        let moved = await waitUntil { gateway.currentChat["default"] == "s_fresh" }
        XCTAssertTrue(moved, "Hermes' own notice of a new chat (a system message) moves the chat to it")
    }
}
