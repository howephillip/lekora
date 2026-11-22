import XCTest
@testable import Lekora

/// Skills (docs/skills.md).
@MainActor
final class SkillsTests: XCTestCase {
    private var host: FakeHost!

    override func setUp() async throws {
        host = try FakeHost()
        host.profiles = [["profile_id": "default", "name": "Home", "avatar": "sparkles"]]
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
                      enabledProfileIds: ["default"], activeProfileId: "default").save(to: store)
        let gateway = GatewayClient(keychain: store, requireTLS: false)
        await gateway.resumeSavedSession()
        _ = await waitUntil { !gateway.timeline.entries.isEmpty }
        return gateway
    }

    func testListAndTurnOff() async throws {
        let gateway = try await connected()
        let skills = try await gateway.skills(for: "default")
        XCTAssertEqual(skills.map(\.name), ["golf", "hermes-agent"])
        XCTAssertEqual(skills.last?.essential, true)
        let off = try await gateway.setSkill("golf", enabled: false, for: "default")
        XCTAssertFalse(off.enabled)
        let sent = host.received(type: "skill.enable").compactMap { $0["profile_id"] as? String }
        XCTAssertEqual(sent, ["default"])
    }

    func testCatalogScanThenInstall() async throws {
        let gateway = try await connected()
        let found = try await gateway.searchSkills("pdf")
        XCTAssertEqual(found.first?.identifier, "official/pdf")
        let scan = try await gateway.scanSkill("official/pdf")
        XCTAssertEqual(scan.policy, "allow")
        XCTAssertEqual(scan.verdict, "safe")
        let installed = try await gateway.installSkill("official/pdf", for: "default")
        XCTAssertEqual(installed.source, "hub")
    }

    func testDraftComesBackWithAHeader() async throws {
        let gateway = try await connected()
        let draft = try await gateway.draftSkill("A weekly review")
        XCTAssertEqual(draft.name, "weekly-review")
        XCTAssertTrue(draft.content.hasPrefix("---\nname: weekly-review"))
    }

    func testWords() {
        XCTAssertEqual(LKSkillText.source("local"), "Made Here")
        XCTAssertEqual(LKSkillText.source("hub"), "From the Catalog")
        XCTAssertEqual(LKSkillText.trust("builtin"), "Official")
        XCTAssertEqual(LKSkillText.trust("community"), "Community")
        XCTAssertEqual(LKSkillText.verdict("dangerous"), "Dangerous")
    }
}
