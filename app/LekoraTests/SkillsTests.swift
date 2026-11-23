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

    func testEverySkillWithItsAgentsThenGiveItToAnother() async throws {
        let gateway = try await connected()
        let all = try await gateway.allSkills()
        XCTAssertEqual(all.map(\.name), ["golf", "hermes-agent"])
        XCTAssertEqual(all.first?.agents.map(\.profile_id), ["default"])
        let copied = try await gateway.copySkill("golf", from: "default", to: ["coder"])
        XCTAssertEqual(copied.added, ["coder"])
        let sent = host.received(type: "skill.copy").first
        XCTAssertEqual(sent?["profile_id"] as? String, "default")
        XCTAssertEqual((sent?["data"] as? [String: Any])?["to"] as? [String], ["coder"])
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

    /// MCP servers (docs/mcp.md): list, add from the registry, then sign in on the phone.
    func testMcpServersAddAndSignIn() async throws {
        let gateway = try await connected()
        let servers = try await gateway.mcpServers()
        XCTAssertEqual(servers.map(\.name), ["deepwiki"])
        XCTAssertEqual(servers.first?.agents.first?.tools, "all")
        let found = try await gateway.searchMcpRegistry("weather")
        XCTAssertEqual(found.first?.runnable, true)
        let added = try await gateway.addMcpServer(McpAddRequest(source: "registry", name: "weather", id: "io.github.acme/weather",
                                                                 to: ["default"]))
        XCTAssertEqual(added.added, ["default"])
        XCTAssertEqual(added.test?.sign_in, true, "it asks for an account sign-in")
        let sent = host.received(type: "mcp.add").first
        XCTAssertEqual((sent?["data"] as? [String: Any])?["source"] as? String, "registry")
        XCTAssertNil((sent?["data"] as? [String: Any])?["bearer"], "nothing that isn't set is sent")
        let started = try await gateway.startMcpSignIn("weather", for: "default", redirect: McpSignInButton.appReturn)
        XCTAssertEqual(started.status, "authorization_required")
        let done = try await gateway.finishMcpSignIn(started.flow_id ?? "", callback: URL(string: "lekora://mcp-oauth?code=c&state=s1")!)
        XCTAssertEqual(done.status, "approved")
        let listed = try await gateway.mcpServers()
        XCTAssertEqual(listed.last?.agents.first?.signed_in, false, "the list comes from Hermes")
        XCTAssertEqual(LKMcpText.source("registry"), "Public Registry (not vetted)")
    }

    func testLekorasOwnSkillIsLabelled() {
        XCTAssertEqual(LKSkillText.source("lekora"), "From Lekora")
    }

    func testWords() {
        XCTAssertEqual(LKSkillText.source("local"), "Made Here")
        XCTAssertEqual(LKSkillText.source("hub"), "From the Catalog")
        XCTAssertEqual(LKSkillText.trust("builtin"), "Official")
        XCTAssertEqual(LKSkillText.trust("community"), "Community")
        XCTAssertEqual(LKSkillText.verdict("dangerous"), "Dangerous")
    }
}
