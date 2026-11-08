import XCTest
@testable import Lekora

/// Choosing which agents (Hermes profiles) this phone uses, and switching between them.
@MainActor
final class AgentSwitchingTests: XCTestCase {
    private var host: FakeHost!

    override func setUp() async throws {
        host = try FakeHost()
        host.profiles = [
            ["profile_id": "default", "name": "Home", "avatar": "sparkles"],
            ["profile_id": "work", "name": "Work", "avatar": "sparkles", "description": "Email and calendar"],
            ["profile_id": "coder", "name": "Coder", "avatar": "sparkles"],
        ]
        host.history = [
            (1, "user", "Plan my weekend", "default"),
            (2, "assistant", "How about a hike?", "default"),
            (3, "user", "Draft the report", "work"),
            (4, "assistant", "Here's a draft.", "work"),
        ]
        try await host.start()
    }

    override func tearDown() async throws {
        host.stop()
        host = nil
    }

    private func pairedGateway(_ store: InMemoryCredentialStore = InMemoryCredentialStore()) async -> GatewayClient {
        let gateway = GatewayClient(keychain: store, requireTLS: false)
        await gateway.pairAndConnect(pairingToken: host.validPairingToken, instanceId: host.instanceId,
                                     candidateEndpoints: [host.endpoint])
        return gateway
    }

    private func sentProfiles() -> [String] {
        host.received(type: "chat.send").compactMap { $0["profile_id"] as? String }
    }

    // MARK: - Choosing

    func testSeveralAgentsAskToChooseAfterPairing() async {
        let gateway = await pairedGateway()
        XCTAssertTrue(gateway.needsProfileChoice)
        XCTAssertEqual(gateway.profiles.map(\.profile_id), ["default", "work", "coder"])
        XCTAssertEqual(gateway.profiles[1].description, "Email and calendar")
        XCTAssertTrue(gateway.enabledProfiles.isEmpty)
    }

    func testSingleAgentIsChosenAutomatically() async {
        host.profiles = [["profile_id": "default", "name": "Home", "avatar": "sparkles"]]
        let store = InMemoryCredentialStore()
        let gateway = await pairedGateway(store)
        XCTAssertFalse(gateway.needsProfileChoice)
        XCTAssertEqual(gateway.enabledProfiles.map(\.profile_id), ["default"])
        XCTAssertEqual(store.values["enabled_profiles"], "default")
    }

    func testChoiceKeepsHostOrderAndIsSavedForNextLaunch() async {
        let store = InMemoryCredentialStore()
        let gateway = await pairedGateway(store)

        gateway.chooseProfiles(["coder", "work", "not-a-profile"])

        XCTAssertFalse(gateway.needsProfileChoice)
        XCTAssertEqual(gateway.enabledProfiles.map(\.profile_id), ["work", "coder"], "host order, unknown ids dropped")
        XCTAssertEqual(gateway.activeProfileId, "work")

        let relaunched = GatewayClient(keychain: store, requireTLS: false)
        await relaunched.resumeSavedSession()
        XCTAssertFalse(relaunched.needsProfileChoice, "no chooser on the next launch")
        XCTAssertEqual(relaunched.enabledProfiles.map(\.profile_id), ["work", "coder"])
        XCTAssertEqual(relaunched.activeProfileId, "work")
    }

    func testEmptyChoiceIsRefused() async {
        let gateway = await pairedGateway()
        gateway.chooseProfiles([])
        XCTAssertTrue(gateway.needsProfileChoice)
    }

    // MARK: - Switching

    func testSwitchingRoutesMessagesToThatAgent() async {
        let gateway = await pairedGateway()
        gateway.chooseProfiles(["default", "work", "coder"])

        await gateway.sendMessage("hi home")
        gateway.switchToProfile("coder")
        await gateway.sendMessage("fix the build")

        _ = await waitUntil { self.sentProfiles().count == 2 }  // let both reach the host
        XCTAssertEqual(sentProfiles(), ["default", "coder"])
        let replied = await waitUntil { gateway.timeline.entries(for: "coder").last?.text == "coder says: fix the build" }
        XCTAssertTrue(replied)
        XCTAssertFalse(gateway.timeline.entries(for: "default").contains { $0.text == "fix the build" })
    }

    func testEachAgentShowsOnlyItsOwnHistory() async {
        let gateway = await pairedGateway()
        gateway.chooseProfiles(["default", "work", "coder"])
        _ = await waitUntil { gateway.timeline.entries.count == 4 }

        XCTAssertEqual(gateway.timeline.entries(for: "default").map(\.text), ["Plan my weekend", "How about a hike?"])
        XCTAssertEqual(gateway.timeline.entries(for: "work").map(\.text), ["Draft the report", "Here's a draft."])
        XCTAssertTrue(gateway.timeline.entries(for: "coder").isEmpty)
    }

    func testCannotSwitchToAnAgentThatIsNotChosen() async {
        let gateway = await pairedGateway()
        gateway.chooseProfiles(["work"])
        gateway.switchToProfile("coder")
        XCTAssertEqual(gateway.activeProfileId, "work")
    }

    func testActiveAgentIsRememberedAcrossLaunches() async {
        let store = InMemoryCredentialStore()
        let gateway = await pairedGateway(store)
        gateway.chooseProfiles(["default", "work", "coder"])
        gateway.switchToProfile("coder")

        let relaunched = GatewayClient(keychain: store, requireTLS: false)
        await relaunched.resumeSavedSession()
        XCTAssertEqual(relaunched.activeProfileId, "coder")
    }

    // MARK: - Agents changing on the host

    func testAgentDeletedOnHostIsDroppedAndActiveFallsBack() async throws {
        let store = InMemoryCredentialStore()
        let gateway = await pairedGateway(store)
        gateway.chooseProfiles(["work", "coder"])
        gateway.switchToProfile("coder")
        gateway.disconnect()

        host.profiles.removeAll { $0["profile_id"] == "coder" }
        await gateway.resumeSavedSession()

        XCTAssertEqual(gateway.enabledProfiles.map(\.profile_id), ["work"])
        XCTAssertEqual(gateway.activeProfileId, "work")
        XCTAssertEqual(store.values["enabled_profiles"], "work")
    }

    func testAllChosenAgentsDeletedAsksAgain() async {
        let gateway = await pairedGateway()
        gateway.chooseProfiles(["coder"])
        gateway.disconnect()

        host.profiles.removeAll { $0["profile_id"] == "coder" }
        await gateway.resumeSavedSession()

        XCTAssertTrue(gateway.needsProfileChoice)
    }

    func testNewAgentOnHostIsOfferedButNotEnabledAutomatically() async {
        let gateway = await pairedGateway()
        gateway.chooseProfiles(["work"])
        gateway.disconnect()

        host.profiles.append(["profile_id": "research", "name": "Research", "avatar": "sparkles"])
        await gateway.resumeSavedSession()

        XCTAssertTrue(gateway.profiles.contains { $0.profile_id == "research" }, "offered in Choose Agents")
        XCTAssertEqual(gateway.enabledProfiles.map(\.profile_id), ["work"])
    }

    func testMessageToAgentRemovedMeanwhileIsMarkedNotDelivered() async {
        let gateway = await pairedGateway()
        gateway.chooseProfiles(["work", "coder"])
        gateway.switchToProfile("coder")
        host.profiles.removeAll { $0["profile_id"] == "coder" }  // deleted while connected

        await gateway.sendMessage("still there?")

        let failed = await waitUntil {
            if case .failed = gateway.timeline.entries(for: "coder").last?.status { return true }
            return false
        }
        XCTAssertTrue(failed)
    }

    func testForgetHostClearsTheAgentChoice() async {
        let store = InMemoryCredentialStore()
        let gateway = await pairedGateway(store)
        gateway.chooseProfiles(["work"])

        await gateway.forgetHost()

        XCTAssertNil(store.values["enabled_profiles"])
        XCTAssertNil(store.values["active_profile"])
    }

    // MARK: - Protocol

    func testProfileDescriptionIsOptionalOnTheWire() throws {
        let withDescription = #"{"profile_id":"work","name":"Work","avatar":"sparkles","description":"Email"}"#
        let without = #"{"profile_id":"default","name":"Home","avatar":"sparkles"}"#
        XCTAssertEqual(try JSONDecoder().decode(ProfileData.self, from: Data(withDescription.utf8)).description, "Email")
        XCTAssertNil(try JSONDecoder().decode(ProfileData.self, from: Data(without.utf8)).description)
    }
}
