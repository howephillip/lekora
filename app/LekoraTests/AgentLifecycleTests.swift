import XCTest
@testable import Lekora

/// Creating and deleting agents from the phone (docs/agent-lifecycle.md).
@MainActor
final class AgentLifecycleTests: XCTestCase {
    private var host: FakeHost!

    override func setUp() async throws {
        host = try FakeHost()
        host.profiles = [
            ["profile_id": "default", "name": "Default", "avatar": "sparkles"],
            ["profile_id": "bruce", "name": "Bruce", "avatar": "sparkles"],
        ]
        host.history = [
            (1, "user", "hi bruce", "bruce"),
            (2, "assistant", "Bruce here.", "bruce"),
        ]
        try await host.start()
    }

    override func tearDown() async throws {
        host.stop()
        host = nil
    }

    private func connectedGateway(choose: [String]? = ["default", "bruce"],
                                  store: InMemoryCredentialStore = InMemoryCredentialStore()) async -> GatewayClient {
        let gateway = GatewayClient(keychain: store, requireTLS: false)
        await gateway.pairAndConnect(pairingToken: host.validPairingToken, instanceId: host.instanceId,
                                     candidateEndpoints: [host.endpoint])
        if let choose { gateway.chooseProfiles(choose) }
        return gateway
    }

    private func hostError(_ work: () async throws -> Void) async -> HostError? {
        do {
            try await work()
            return nil
        } catch {
            return error as? HostError
        }
    }

    // MARK: - Naming

    func testNamingMatchesTheHostRule() {
        XCTAssertEqual(ProfileNaming.id(for: "Research Assistant"), "research-assistant")
        XCTAssertEqual(ProfileNaming.id(for: "  Bruce  "), "bruce")
        XCTAssertEqual(ProfileNaming.id(for: "Q3 / Finance!!"), "q3-finance")
        XCTAssertEqual(ProfileNaming.id(for: String(repeating: "a", count: 80)).count, 64)
        XCTAssertEqual(ProfileNaming.id(for: "!!!"), "")
    }

    // MARK: - Create

    func testCreateSendsNameAndDescriptionAndSwitchesToTheNewAgent() async throws {
        let gateway = await connectedGateway()

        let created = try await gateway.createProfile(name: "Research Assistant", description: "  Finds sources ")

        XCTAssertEqual(created.profile_id, "research-assistant")
        let request = try XCTUnwrap(host.received(type: "profile.create").first?["data"] as? [String: Any])
        XCTAssertEqual(request["name"] as? String, "Research Assistant")
        XCTAssertEqual(request["description"] as? String, "Finds sources")
        XCTAssertTrue(gateway.enabledProfiles.contains { $0.profile_id == "research-assistant" })
        XCTAssertEqual(gateway.activeProfileId, "research-assistant")
    }

    func testCreateDuringSetupDoesNotSkipTheChooser() async throws {
        let gateway = await connectedGateway(choose: nil)
        XCTAssertTrue(gateway.needsProfileChoice)

        try await gateway.createProfile(name: "Research")

        XCTAssertTrue(gateway.needsProfileChoice, "the user still finishes Choose Your Agents")
        XCTAssertTrue(gateway.profiles.contains { $0.profile_id == "research" })
    }

    func testCreateErrorsComeBackReadable() async {
        let gateway = await connectedGateway()
        let duplicate = await hostError { try await gateway.createProfile(name: "Bruce") }
        XCTAssertEqual(duplicate?.code, "PROFILE_EXISTS")
        let invalid = await hostError { try await gateway.createProfile(name: "!!!") }
        XCTAssertEqual(invalid?.code, "INVALID_NAME")
        // Still usable afterwards.
        let created = try? await gateway.createProfile(name: "Ok")
        XCTAssertEqual(created?.profile_id, "ok")
    }

    func testDisconnectWhileWaitingFailsTheRequestInsteadOfHanging() async {
        let gateway = await connectedGateway()
        host.ignoreCreates = true
        async let outcome = hostError { try await gateway.createProfile(name: "Slow") }
        _ = await waitUntil { !self.host.received(type: "profile.create").isEmpty }
        gateway.disconnect()
        let error = await outcome
        XCTAssertEqual(error?.code, "DISCONNECTED")
    }

    func testCreateWhenNotConnectedFails() async {
        let gateway = GatewayClient(keychain: InMemoryCredentialStore(), requireTLS: false)
        let error = await hostError { try await gateway.createProfile(name: "x") }
        XCTAssertEqual(error?.code, "DISCONNECTED")
    }

    // MARK: - Delete

    func testDeleteSendsExplicitConfirmationAndRemovesTheAgent() async throws {
        let gateway = await connectedGateway()
        gateway.switchToProfile("bruce")
        _ = await waitUntil { gateway.timeline.entries(for: "bruce").count == 2 }

        let backup = try await gateway.deleteProfile("bruce")

        let request = try XCTUnwrap(host.received(type: "profile.delete").first?["data"] as? [String: Any])
        XCTAssertEqual(request["profile_id"] as? String, "bruce")
        XCTAssertEqual(request["confirm"] as? String, "bruce")
        XCTAssertTrue(backup.contains("bruce"))
        XCTAssertFalse(gateway.profiles.contains { $0.profile_id == "bruce" })
        XCTAssertEqual(gateway.enabledProfiles.map(\.profile_id), ["default"])
        XCTAssertEqual(gateway.activeProfileId, "default", "moved off the deleted agent")
        XCTAssertTrue(gateway.timeline.entries(for: "bruce").isEmpty)
    }

    func testDeletingDefaultIsRefused() async {
        let gateway = await connectedGateway()
        let error = await hostError { try await gateway.deleteProfile("default") }
        XCTAssertEqual(error?.code, "CANNOT_DELETE_DEFAULT")
        XCTAssertTrue(gateway.profiles.contains { $0.profile_id == "default" })
    }

    func testFailedDeleteKeepsEverything() async {
        let gateway = await connectedGateway()
        host.failNextDelete = true
        let error = await hostError { try await gateway.deleteProfile("bruce") }
        XCTAssertEqual(error?.code, "BACKUP_FAILED")
        XCTAssertEqual(gateway.enabledProfiles.map(\.profile_id), ["default", "bruce"])
    }

    func testDeletingTheOnlyChosenAgentAsksToChooseAgain() async throws {
        let gateway = await connectedGateway(choose: ["bruce"])
        try await gateway.deleteProfile("bruce")
        XCTAssertTrue(gateway.needsProfileChoice)
    }

    // MARK: - Other phones

    func testOtherPhonesUpdateLiveWhenAgentsChange() async throws {
        let phoneA = await connectedGateway()
        let phoneB = await connectedGateway()
        phoneB.switchToProfile("bruce")

        try await phoneA.createProfile(name: "Research")
        let sawCreate = await waitUntil { phoneB.profiles.contains { $0.profile_id == "research" } }
        XCTAssertTrue(sawCreate)
        XCTAssertFalse(phoneB.enabledProfiles.contains { $0.profile_id == "research" },
                       "new agents are offered, not switched on, on other phones")

        try await phoneA.deleteProfile("bruce")
        let sawDelete = await waitUntil { !phoneB.profiles.contains { $0.profile_id == "bruce" } }
        XCTAssertTrue(sawDelete)
        XCTAssertEqual(phoneB.activeProfileId, "default")
        XCTAssertTrue(phoneB.timeline.entries(for: "bruce").isEmpty)
    }
}
