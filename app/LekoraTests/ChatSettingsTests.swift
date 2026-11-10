import XCTest
@testable import Lekora

/// Per-chat settings (docs/chat-settings.md).
@MainActor
final class ChatSettingsTests: XCTestCase {
    private func connected(_ host: FakeHost) async throws -> GatewayClient {
        let store = InMemoryCredentialStore()
        try SavedHost(instanceId: host.instanceId, instanceName: host.instanceName, deviceId: "dev_1",
                      deviceToken: host.acceptedDeviceToken, endpoints: [host.endpoint],
                      enabledProfileIds: ["assistant"], activeProfileId: "assistant").save(to: store)
        let gateway = GatewayClient(keychain: store, requireTLS: false)
        await gateway.resumeSavedSession()
        return gateway
    }

    func testSettingsLoadFromTheHost() async throws {
        let host = try FakeHost()
        try await host.start()
        defer { host.stop() }
        let gateway = try await connected(host)
        await gateway.loadSettings(for: "assistant")
        let settings = try XCTUnwrap(gateway.chatSettings["assistant"])
        XCTAssertEqual(settings.model?.model, "anthropic/claude-opus-5-5")
        XCTAssertEqual(settings.reasoning?.effort, "medium")
        XCTAssertEqual(settings.title, "Ramen plans")
        XCTAssertEqual(settings.personality?.options.map(\.name), ["pirate"])
        XCTAssertEqual(settings.usage?.context_length, 200000)
        XCTAssertEqual(settings.runsWithoutAsking, false)
        XCTAssertEqual(host.received(type: "settings.get").last?["profile_id"] as? String, "assistant")
    }

    func testAutoApproveShowsStraightAway() async throws {
        let host = try FakeHost()
        try await host.start()
        defer { host.stop() }
        let gateway = try await connected(host)
        await gateway.loadSettings(for: "assistant")
        try await gateway.changeSetting("yolo", to: .flag(true), in: "assistant")
        XCTAssertEqual(gateway.chatSettings["assistant"]?.runsWithoutAsking, true, "the amber badge shows")
        let sent = try XCTUnwrap(host.received(type: "settings.set").last?["data"] as? [String: Any])
        XCTAssertEqual(sent["key"] as? String, "yolo")
        XCTAssertEqual(sent["value"] as? Bool, true)

        try await gateway.changeSetting("yolo", to: .flag(false), in: "assistant")
        try await gateway.changeSetting("approvals", to: .text("off"), in: "assistant")
        XCTAssertEqual(gateway.chatSettings["assistant"]?.runsWithoutAsking, true, "approvals off also runs without asking")
    }

    func testARefusedChangeKeepsTheOldValue() async throws {
        let host = try FakeHost()
        try await host.start()
        defer { host.stop() }
        let gateway = try await connected(host)
        await gateway.loadSettings(for: "assistant")
        do {
            try await gateway.changeSetting("fast", to: .text("warp"), in: "assistant")
            XCTFail("should be refused")
        } catch {}
        XCTAssertEqual(gateway.chatSettings["assistant"]?.fast, "normal")
    }

    func testActionsGoToTheHost() async throws {
        let host = try FakeHost()
        try await host.start()
        defer { host.stop() }
        let gateway = try await connected(host)
        try await gateway.runChatAction("compress", in: "assistant")
        let sent = try XCTUnwrap(host.received(type: "settings.action").last?["data"] as? [String: Any])
        XCTAssertEqual(sent["action"] as? String, "compress")
    }

    func testUnknownPartsDecode() throws {
        let json = #"{"model": null, "reasoning": null, "show_reasoning": null, "fast": null, "yolo": null,"#
            + #" "personality": null, "approvals": null, "title": null, "usage": null}"#
        let settings = try JSONDecoder().decode(ChatSettingsData.self, from: Data(json.utf8))
        XCTAssertNil(settings.model)
        XCTAssertFalse(settings.runsWithoutAsking)
    }
}
