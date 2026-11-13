import XCTest
@testable import Lekora

/// Several Hermes computers in one app (docs/multiple-instances.md).
@MainActor
final class MultipleComputersTests: XCTestCase {
    private var pi: FakeHost!
    private var mac: FakeHost!

    override func setUp() async throws {
        pi = try FakeHost(instanceId: "inst_pi", instanceName: "Pi")
        mac = try FakeHost(instanceId: "inst_mac", instanceName: "omacron")
        // Both have an agent called "default".
        pi.profiles = [["profile_id": "default", "name": "Default", "avatar": "sparkles"]]
        mac.profiles = [["profile_id": "default", "name": "Default", "avatar": "sparkles"]]
        pi.history = [(1, "assistant", "From the Pi", "default")]
        mac.history = [(1, "assistant", "From the Mac", "default")]
        try await pi.start()
        try await mac.start()
    }

    override func tearDown() async throws {
        pi.stop()
        mac.stop()
    }

    private func saved(_ host: FakeHost) -> SavedHost {
        SavedHost(instanceId: host.instanceId, instanceName: host.instanceName, deviceId: "dev_1",
                  deviceToken: host.acceptedDeviceToken, endpoints: [host.endpoint],
                  enabledProfileIds: ["default"], activeProfileId: "default")
    }

    private func model(_ store: InMemoryCredentialStore) -> HostsModel {
        HostsModel(keychain: store) { start in GatewayClient(keychain: store, requireTLS: false, start: start) }
    }

    /// Connects every computer and waits for their messages to arrive.
    private func connectAll(_ hosts: HostsModel) async {
        await hosts.resumeAll()
        _ = await waitUntil { hosts.clients.allSatisfy { !$0.timeline.entries(for: "default").isEmpty } }
    }

    private func bothSaved() throws -> InMemoryCredentialStore {
        let store = InMemoryCredentialStore()
        try saved(pi).save(to: store)
        try saved(mac).save(to: store)
        return store
    }

    // MARK: - Saved on the phone

    func testAnOldSinglePairingMovesOver() throws {
        let store = InMemoryCredentialStore()
        for (key, value) in ["instance_id": "inst_pi", "instance_name": "Pi", "device_id": "dev_1",
                             "device_token": "tok_good", "endpoints": "wss://pi:1", "cert_pin": "abc",
                             "enabled_profiles": "default\nwork", "active_profile": "work"] {
            try store.save(key: key, value: value)
        }
        let hosts = SavedHost.loadAll(from: store)
        XCTAssertEqual(hosts.map(\.instanceId), ["inst_pi"])
        XCTAssertEqual(hosts.first?.enabledProfileIds, ["default", "work"])
        XCTAssertEqual(hosts.first?.certPin, "abc")
        XCTAssertNil(store.values["device_token"], "the old keys are gone")
        XCTAssertEqual(store.values["host.inst_pi.device_token"], "tok_good")
        XCTAssertEqual(SavedHost.loadAll(from: store).count, 1, "moved only once")
    }

    func testForgettingOneKeepsTheOther() throws {
        let store = try bothSaved()
        XCTAssertEqual(SavedHost.loadAll(from: store).map(\.instanceId), ["inst_pi", "inst_mac"])
        SavedHost.clear(instanceId: "inst_pi", from: store)
        XCTAssertEqual(SavedHost.loadAll(from: store).map(\.instanceId), ["inst_mac"])
        XCTAssertNil(store.values["host.inst_pi.device_token"])
    }

    // MARK: - Connected to both

    func testBothConnectAndAgentsStaySeparate() async throws {
        let hosts = model(try bothSaved())
        await connectAll(hosts)
        XCTAssertEqual(hosts.clients.count, 2)
        XCTAssertTrue(hosts.hasSeveral)
        let agents = hosts.agentsByRecency
        XCTAssertEqual(Set(agents.map(\.key)), [AgentKey(instanceId: "inst_pi", profileId: "default"),
                                               AgentKey(instanceId: "inst_mac", profileId: "default")])
        let piClient = try XCTUnwrap(hosts.client(for: "inst_pi"))
        let macClient = try XCTUnwrap(hosts.client(for: "inst_mac"))
        XCTAssertEqual(piClient.timeline.entries(for: "default").map(\.text), ["From the Pi"])
        XCTAssertEqual(macClient.timeline.entries(for: "default").map(\.text), ["From the Mac"])
        XCTAssertNotEqual(piClient.avatarPalettes["default"], macClient.avatarPalettes["default"],
                          "two agents called default get different colours")

        // Sending goes to the right computer only.
        await macClient.sendMessage("Hi Mac")
        let ok348 = await waitUntil { self.mac.received(type: "chat.send").count == 1 }
        XCTAssertTrue(ok348)
        XCTAssertTrue(pi.received(type: "chat.send").isEmpty)
    }

    func testNewestConversationFirstAcrossComputers() async throws {
        pi.messageTime = "2026-11-10T09:00:00Z"
        mac.messageTime = "2026-11-10T10:00:00Z"
        let hosts = model(try bothSaved())
        await connectAll(hosts)
        XCTAssertEqual(hosts.agentsByRecency.map(\.key.instanceId), ["inst_mac", "inst_pi"])
    }

    func testOneOfflineDoesNotStopTheOther() async throws {
        mac.stop()
        let hosts = model(try bothSaved())
        await hosts.resumeAll()
        XCTAssertEqual(hosts.clients.count, 2, "the offline computer stays paired")
        guard case .connected = try XCTUnwrap(hosts.client(for: "inst_pi")).state else { return XCTFail("Pi should connect") }
        if case .connected = try XCTUnwrap(hosts.client(for: "inst_mac")).state { XCTFail("the Mac is off") }
    }

    func testMessagesForAnotherComputerAreIgnored() async throws {
        let store = InMemoryCredentialStore()
        try saved(pi).save(to: store)
        let gateway = GatewayClient(keychain: store, requireTLS: false)
        await gateway.resumeSavedSession()
        pi.pretendInstanceId = "inst_somewhere_else"
        pi.say(profile: "default", text: "Not for you")
        pi.pretendInstanceId = nil
        pi.say(profile: "default", text: "For you")
        let ok340 = await waitUntil { gateway.timeline.entries(for: "default").contains { $0.text == "For you" } }
        XCTAssertTrue(ok340)
        XCTAssertFalse(gateway.timeline.entries(for: "default").contains { $0.text == "Not for you" })
    }

    // MARK: - Pairing another, renaming, forgetting

    func testPairingASecondComputerKeepsTheFirst() async throws {
        let store = InMemoryCredentialStore()
        try saved(pi).save(to: store)
        let hosts = model(store)
        await hosts.resumeAll()
        let pairing = hosts.pairing
        await pairing.pairAndConnect(pairingToken: mac.validPairingToken, instanceId: mac.instanceId,
                                     candidateEndpoints: [mac.endpoint])
        XCTAssertEqual(hosts.clients.map { $0.savedHost?.instanceId }, ["inst_pi", "inst_mac"])
        XCTAssertFalse(hosts.pairing === pairing, "a fresh client waits for the next pairing")
        XCTAssertEqual(SavedHost.loadAll(from: store).map(\.instanceId), ["inst_pi", "inst_mac"])
        guard case .connected = try XCTUnwrap(hosts.client(for: "inst_pi")).state else { return XCTFail("Pi still connected") }
    }

    func testPairingTheSameComputerAgainReplacesIt() async throws {
        let store = InMemoryCredentialStore()
        try saved(pi).save(to: store)
        let hosts = model(store)
        await hosts.resumeAll()
        let old = try XCTUnwrap(hosts.clients.first)
        await hosts.pairing.pairAndConnect(pairingToken: pi.validPairingToken, instanceId: pi.instanceId,
                                           candidateEndpoints: [pi.endpoint])
        XCTAssertEqual(hosts.clients.count, 1)
        XCTAssertFalse(hosts.clients.first === old)
    }

    func testRenamingAComputer() async throws {
        let store = InMemoryCredentialStore()
        try saved(pi).save(to: store)
        let gateway = GatewayClient(keychain: store, requireTLS: false)
        await gateway.resumeSavedSession()
        try await gateway.renameInstance("Home Pi")
        XCTAssertEqual(gateway.savedHost?.instanceName, "Home Pi")
        XCTAssertEqual(SavedHost.load(from: store)?.instanceName, "Home Pi", "kept on the phone too")
        XCTAssertEqual(pi.received(type: "instance.rename").last.flatMap { ($0["data"] as? [String: Any])?["name"] as? String },
                       "Home Pi")

        pi.renameElsewhere("Office Pi")  // from another phone
        let ok949 = await waitUntil { gateway.savedHost?.instanceName == "Office Pi" }
        XCTAssertTrue(ok949)
    }

    /// What the agents call you (docs/your-name.md): kept on the instance, not the phone.
    func testYourNameIsKeptOnTheInstance() async throws {
        pi.userName = "Phil"
        let store = InMemoryCredentialStore()
        try saved(pi).save(to: store)
        let gateway = GatewayClient(keychain: store, requireTLS: false)
        await gateway.resumeSavedSession()
        XCTAssertEqual(gateway.userName, "Phil", "a new phone gets it from the instance")
        try await gateway.setUserName("Phillip")
        XCTAssertEqual(gateway.userName, "Phillip")
        XCTAssertEqual(pi.userName, "Phillip")
        pi.userNameElsewhere("P")  // changed on another phone
        let followed = await waitUntil { gateway.userName == "P" }
        XCTAssertTrue(followed)
    }

    func testAnOlderPluginHasNoNameToAskFor() async throws {
        pi.userName = nil
        let store = InMemoryCredentialStore()
        try saved(pi).save(to: store)
        let gateway = GatewayClient(keychain: store, requireTLS: false)
        await gateway.resumeSavedSession()
        XCTAssertNil(gateway.userName, "setup doesn't ask; Your Name says it needs updating")
    }

    func testTheNameFromTheComputerWinsOnConnect() async throws {
        let store = InMemoryCredentialStore()
        var old = saved(pi)
        old.instanceName = "Old name"
        try old.save(to: store)
        let gateway = GatewayClient(keychain: store, requireTLS: false)
        await gateway.resumeSavedSession()
        XCTAssertEqual(gateway.savedHost?.instanceName, "Pi")
    }

    func testForgettingOneComputer() async throws {
        let store = try bothSaved()
        let hosts = model(store)
        await hosts.resumeAll()
        let message = await hosts.forget(try XCTUnwrap(hosts.client(for: "inst_mac")))
        XCTAssertNil(message, "the Mac removed this phone")
        XCTAssertTrue(mac.unpaired)
        XCTAssertEqual(hosts.clients.map { $0.savedHost?.instanceId }, ["inst_pi"])
        XCTAssertEqual(SavedHost.loadAll(from: store).map(\.instanceId), ["inst_pi"])
        guard case .connected = try XCTUnwrap(hosts.client(for: "inst_pi")).state else { return XCTFail("Pi unaffected") }
    }
}
