import XCTest
@testable import Lekora

@MainActor
final class AutoReconnectTests: XCTestCase {
    private var host: FakeHost!

    override func setUp() async throws {
        host = try FakeHost()
        try await host.start()
    }

    override func tearDown() async throws {
        host.stop()
        host = nil
    }

    private func savedStore(token: String? = nil, endpoints: [String]? = nil) throws -> InMemoryCredentialStore {
        let store = InMemoryCredentialStore()
        try SavedHost(
            instanceId: host.instanceId,
            instanceName: host.instanceName,
            deviceId: "dev_1",
            deviceToken: token ?? host.acceptedDeviceToken,
            endpoints: endpoints ?? [host.endpoint]
        ).save(to: store)
        return store
    }

    // MARK: - Saved credentials

    func testSavedHostRoundTrip() throws {
        let store = try savedStore()
        let loaded = try XCTUnwrap(SavedHost.load(from: store))
        XCTAssertEqual(loaded.instanceName, "Test Host")
        XCTAssertEqual(loaded.endpoints, [host.endpoint])
    }

    func testPairingFromBeforeEndpointsWereSavedCountsAsNotPaired() throws {
        let store = InMemoryCredentialStore()
        try store.save(key: "instance_id", value: "inst_old")
        try store.save(key: "device_id", value: "dev_old")
        try store.save(key: "device_token", value: "tok_old")
        XCTAssertNil(SavedHost.load(from: store))
    }

    func testEndpointOrderPutsWinnerFirstWithoutDuplicates() {
        let ordered = SavedHost.orderedEndpoints(
            preferred: URL(string: "ws://b:1"), ["ws://a:1", "ws://b:1"], ["ws://c:1", "ws://a:1"])
        XCTAssertEqual(ordered, ["ws://b:1", "ws://a:1", "ws://c:1"])
    }

    // MARK: - Launch

    func testNoSavedHostShowsSetupWizard() async {
        let gateway = GatewayClient(keychain: InMemoryCredentialStore(), requireTLS: false)
        XCTAssertNil(gateway.savedHost)
        await gateway.resumeSavedSession()
        XCTAssertEqual(gateway.state, .disconnected)
        XCTAssertTrue(host.received.isEmpty)
    }

    func testLaunchReconnectsAndRestoresHistoryFromHost() async throws {
        let gateway = GatewayClient(keychain: try savedStore(), requireTLS: false)
        XCTAssertNotNil(gateway.savedHost)

        await gateway.resumeSavedSession()

        XCTAssertEqual(gateway.state, .connected(instanceName: "Test Host", profileName: "Assistant"))
        let hello = try XCTUnwrap(host.received(type: "hello").first)
        let helloData = try XCTUnwrap(hello["data"] as? [String: Any])
        XCTAssertEqual(helloData["device_token"] as? String, host.acceptedDeviceToken)
        XCTAssertEqual(helloData["last_seq"] as? Int, 0, "fresh launch asks for the whole conversation")

        let restored = await waitUntil { gateway.timeline.entries.count == 2 }
        XCTAssertTrue(restored)
        XCTAssertEqual(gateway.timeline.entries.map(\.text), ["Hello from earlier", "Hi! Welcome back."])
        XCTAssertEqual(gateway.currentSeq, 2)
    }

    func testChatWorksAfterAutomaticReconnect() async throws {
        let gateway = GatewayClient(keychain: try savedStore(), requireTLS: false)
        await gateway.resumeSavedSession()
        _ = await waitUntil { gateway.timeline.entries.count == 2 }

        await gateway.sendMessage("Are you there?")

        let replied = await waitUntil { gateway.timeline.entries.last?.text == "assistant says: Are you there?" }
        XCTAssertTrue(replied)
        let sent = try XCTUnwrap(host.received(type: "chat.send").first)
        XCTAssertEqual(sent["instance_id"] as? String, host.instanceId)
    }

    func testReconnectAfterDropAsksOnlyForNewMessages() async throws {
        let gateway = GatewayClient(keychain: try savedStore(), requireTLS: false)
        await gateway.resumeSavedSession()
        _ = await waitUntil { gateway.timeline.entries.count == 2 }

        gateway.disconnect()
        XCTAssertNotNil(gateway.savedHost, "dropping the connection keeps the pairing")
        await gateway.resumeSavedSession()

        XCTAssertEqual(gateway.state, .connected(instanceName: "Test Host", profileName: "Assistant"))
        let secondHello = try XCTUnwrap(host.received(type: "hello").last?["data"] as? [String: Any])
        XCTAssertEqual(secondHello["last_seq"] as? Int, 2)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(gateway.timeline.entries.count, 2, "no duplicated history")
    }

    func testRepeatedResumeWhileConnectedDoesNothing() async throws {
        let gateway = GatewayClient(keychain: try savedStore(), requireTLS: false)
        await gateway.resumeSavedSession()
        await gateway.resumeSavedSession()
        XCTAssertEqual(host.received(type: "hello").count, 1)
    }

    // MARK: - Failures

    func testRevokedDeviceForgetsHostAndShowsWizard() async throws {
        let store = try savedStore(token: "tok_revoked")
        let gateway = GatewayClient(keychain: store, requireTLS: false)

        await gateway.resumeSavedSession()

        XCTAssertNil(gateway.savedHost)
        XCTAssertTrue(store.values.isEmpty, "credentials removed from the keychain")
        guard case .error(let message) = gateway.state else {
            return XCTFail("expected an explanation, got \(gateway.state)")
        }
        XCTAssertTrue(message.contains("no longer paired"))
    }

    func testUnreachableHostKeepsPairing() async throws {
        let store = try savedStore(endpoints: ["ws://127.0.0.1:1"])
        let gateway = GatewayClient(keychain: store, requireTLS: false)

        await gateway.resumeSavedSession()

        XCTAssertNotNil(gateway.savedHost)
        XCTAssertEqual(store.values["host.\(host.instanceId).device_token"], host.acceptedDeviceToken)
        guard case .error(let message) = gateway.state else {
            return XCTFail("expected an error, got \(gateway.state)")
        }
        XCTAssertTrue(message.contains("Can't reach"))
    }

    // MARK: - Pairing and forgetting

    func testPairingSavesHostForNextLaunch() async throws {
        let store = InMemoryCredentialStore()
        let gateway = GatewayClient(keychain: store, requireTLS: false)

        await gateway.pairAndConnect(pairingToken: host.validPairingToken, instanceId: host.instanceId,
                                     candidateEndpoints: [host.endpoint])

        XCTAssertEqual(gateway.state, .connected(instanceName: "Test Host", profileName: "Assistant"))
        let nextLaunch = GatewayClient(keychain: store, requireTLS: false)
        XCTAssertEqual(nextLaunch.savedHost?.deviceToken, host.acceptedDeviceToken)
        XCTAssertEqual(nextLaunch.savedHost?.endpoints.first, host.endpoint)
    }

    func testInvalidPairingCodeShowsHostReason() async {
        let store = InMemoryCredentialStore()
        let gateway = GatewayClient(keychain: store, requireTLS: false)

        await gateway.pairAndConnect(pairingToken: "used_up", instanceId: host.instanceId,
                                     candidateEndpoints: [host.endpoint])

        XCTAssertEqual(gateway.state, .error("Pairing code is invalid or already used"))
        XCTAssertNil(gateway.savedHost)
        XCTAssertTrue(store.values.isEmpty)
    }

    func testForgetHostClearsEverything() async throws {
        let store = try savedStore()
        let gateway = GatewayClient(keychain: store, requireTLS: false)
        await gateway.resumeSavedSession()
        _ = await waitUntil { gateway.timeline.entries.count == 2 }

        let outcome = await gateway.forgetHost()

        XCTAssertEqual(outcome, .removedFromHost)
        XCTAssertTrue(host.unpaired, "the host was asked to revoke this phone")
        let unpair = try XCTUnwrap(host.received(type: "device.unpair").first?["data"] as? [String: Any])
        XCTAssertEqual(unpair["device_id"] as? String, "dev_1")
        XCTAssertEqual(unpair["device_token"] as? String, host.acceptedDeviceToken)
        XCTAssertFalse(gateway.isForgetting)
        XCTAssertEqual(gateway.state, .disconnected)
        XCTAssertNil(gateway.savedHost)
        XCTAssertTrue(store.values.isEmpty)
        XCTAssertTrue(gateway.timeline.entries.isEmpty)
        XCTAssertNil(GatewayClient(keychain: store, requireTLS: false).savedHost, "next launch shows the setup wizard")
    }

    func testForgetWhileNotConnectedStillRemovesFromHost() async throws {
        // E.g. Forget Host on the Reconnecting screen: no chat socket is open.
        let store = try savedStore()
        let gateway = GatewayClient(keychain: store, requireTLS: false)

        let outcome = await gateway.forgetHost()

        XCTAssertEqual(outcome, .removedFromHost)
        XCTAssertTrue(host.unpaired)
        XCTAssertTrue(host.received(type: "hello").isEmpty, "unpair needs no hello, so no history replay")
        XCTAssertTrue(store.values.isEmpty)
    }

    func testForgetWhenHostUnreachableForgetsLocallyAndExplains() async throws {
        let store = try savedStore(endpoints: ["ws://127.0.0.1:1"])
        let gateway = GatewayClient(keychain: store, requireTLS: false)

        let outcome = await gateway.forgetHost()

        XCTAssertEqual(outcome, .hostUnreachable)
        XCTAssertNil(gateway.savedHost)
        XCTAssertTrue(store.values.isEmpty, "the phone forgets the host anyway")
        guard case .error(let message) = gateway.state else {
            return XCTFail("expected an explanation, got \(gateway.state)")
        }
        XCTAssertTrue(message.contains("hermes lekora devices"))
    }

    func testForgetWhenAlreadyRevokedCountsAsRemoved() async throws {
        host.unpaired = true
        let gateway = GatewayClient(keychain: try savedStore(), requireTLS: false)
        let outcome = await gateway.forgetHost()
        XCTAssertEqual(outcome, .removedFromHost)
        XCTAssertEqual(gateway.state, .disconnected)
    }

    func testPairingSendsDescriptiveDeviceName() async throws {
        let gateway = GatewayClient(keychain: InMemoryCredentialStore(), requireTLS: false)
        await gateway.pairAndConnect(pairingToken: host.validPairingToken, instanceId: host.instanceId,
                                     candidateEndpoints: [host.endpoint])
        let request = try XCTUnwrap(host.received(type: "pair.request").first?["data"] as? [String: Any])
        let name = try XCTUnwrap(request["device_name"] as? String)
        XCTAssertEqual(name, DeviceName.current)
        XCTAssertTrue(name.contains(" · "), "model and OS version, e.g. iPhone19,2 · iOS 27.0.1")
    }
}
