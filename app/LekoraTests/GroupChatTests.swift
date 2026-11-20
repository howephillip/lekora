import XCTest
@testable import Lekora

/// Group chats (docs/group-chats.md).
@MainActor
final class GroupChatTests: XCTestCase {
    private var host: FakeHost!

    override func setUp() async throws {
        host = try FakeHost()
        host.profiles = [
            ["profile_id": "default", "name": "Home", "avatar": "sparkles"],
            ["profile_id": "coder", "name": "Coder", "avatar": "sparkles"],
            ["profile_id": "writer", "name": "Writer", "avatar": "sparkles"],
        ]
        host.history = [(1, "assistant", "Hi", "default")]
        host.groups = [["group_id": "g1", "name": "Launch", "members": ["coder", "writer"], "created_at": "2026-11-19T10:00:00Z"]]
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
                      enabledProfileIds: ["default", "coder", "writer"], activeProfileId: "default").save(to: store)
        let gateway = GatewayClient(keychain: store, requireTLS: false)
        await gateway.resumeSavedSession()
        _ = await waitUntil { !gateway.groups.isEmpty }
        return gateway
    }

    func testGroupsArriveAfterConnecting() async throws {
        let gateway = try await connected()
        XCTAssertEqual(gateway.groups.map(\.name), ["Launch"])
        XCTAssertEqual(gateway.groups.first?.key, "group:g1")
    }

    func testCreateRenameAndDelete() async throws {
        let gateway = try await connected()
        let made = try await gateway.createGroup(name: "Research", members: ["default", "writer"])
        XCTAssertEqual(gateway.groups.map(\.name), ["Launch", "Research"])
        try await gateway.updateGroup(made.group_id, name: "Deep Research")
        XCTAssertEqual(gateway.group(for: made.key)?.name, "Deep Research")
        try await gateway.deleteGroup(made.group_id)
        XCTAssertNil(gateway.group(for: made.key))
    }

    func testAGroupNeedsTwoAgents() async throws {
        let gateway = try await connected()
        do {
            try await gateway.createGroup(name: "Solo", members: ["coder"])
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("two agents"))
        }
    }

    func testChangesFromAnotherPhoneShowHere() async throws {
        let gateway = try await connected()
        host.groups.append(["group_id": "g2", "name": "Ops", "members": ["default", "coder"]])
        host.announceGroups()
        let arrived = await waitUntil { gateway.groups.count == 2 }
        XCTAssertTrue(arrived)
    }

    func testMessagesInAGroupSayWhoSpokeAndWhoIsTyping() async throws {
        let gateway = try await connected()
        gateway.switchToProfile("group:g1")
        XCTAssertEqual(gateway.activeProfileId, "group:g1")
        host.pushMessage(["seq": 2, "role": "assistant", "text": "On it", "rev": 20, "speaker": "coder"], profile: "group:g1")
        let arrived = await waitUntil { gateway.timeline.entries(for: "group:g1").contains { $0.speaker == "coder" } }
        XCTAssertTrue(arrived)
        host.push(type: "chat.draft", data: ["draft_id": "d1", "text": "Draft from writer", "speaker": "writer"], profile: "group:g1")
        let drafted = await waitUntil { gateway.timeline.entries(for: "group:g1").contains { $0.id == "d1" && $0.speaker == "writer" } }
        XCTAssertTrue(drafted)
        host.push(type: "chat.typing", data: ["active": true, "status": "is searching the web", "speaker": "writer"], profile: "group:g1")
        let typing = await waitUntil { gateway.agentActivity["group:g1"]?.status == "Writer is searching the web" }
        XCTAssertTrue(typing)
    }

    func testADeletedGroupsMessagesGo() async throws {
        let gateway = try await connected()
        host.pushMessage(["seq": 2, "role": "assistant", "text": "On it", "rev": 20, "speaker": "coder"], profile: "group:g1")
        _ = await waitUntil { !gateway.timeline.entries(for: "group:g1").isEmpty }
        host.groups = []
        host.announceGroups()
        let gone = await waitUntil { gateway.timeline.entries(for: "group:g1").isEmpty }
        XCTAssertTrue(gone)
    }

    func testMentionSuggestions() {
        let members = [ProfileData(profile_id: "coder", name: "Coder", avatar: "x"),
                       ProfileData(profile_id: "writer", name: "Writer", avatar: "x")]
        XCTAssertEqual(LKMentionMatcher.suggestions(for: "hey @co", members: members).map(\.handle), ["coder"])
        XCTAssertEqual(LKMentionMatcher.suggestions(for: "@", members: members).map(\.handle), ["all", "coder", "writer"])
        XCTAssertTrue(LKMentionMatcher.suggestions(for: "mail me@co", members: members).isEmpty)
        XCTAssertTrue(LKMentionMatcher.suggestions(for: "@coder done", members: members).isEmpty)
        XCTAssertEqual(LKMentionMatcher.complete("hey @co", with: "coder"), "hey @coder ")
    }

    func testGroupKeysAreRecognised() {
        XCTAssertTrue(GroupData.isKey("group:g1"))
        XCTAssertFalse(GroupData.isKey("coder"))
    }

    func testAReusedDraftIdNeverReplacesASavedMessage() {
        var timeline = ChatTimeline()
        timeline.applyDraft(draftId: "d1", profileId: "group:g1", text: "First", speaker: "atlas")
        timeline.applyIncoming(seq: 5, profileId: "group:g1", role: "assistant", text: "First", draftId: "d1", speaker: "atlas")
        timeline.applyIncoming(seq: 6, profileId: "group:g1", role: "assistant", text: "Second", draftId: "d1", speaker: "atlas")
        XCTAssertEqual(timeline.entries(for: "group:g1").map(\.seq), [5, 6])
    }
}
