import XCTest
import Network
@testable import Lekora

/// A relay that holds every chunk for `delay` seconds each way: in-flight Wi-Fi in a test.
final class SlowRelay: @unchecked Sendable {
    let listener: NWListener
    let delay: Double
    private let queue = DispatchQueue(label: "slow-relay")
    private var kept: [NWConnection] = []
    var port: UInt16 { listener.port?.rawValue ?? 0 }

    init(to target: UInt16, delay: Double) throws {
        self.delay = delay
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] inbound in
            guard let self else { return }
            let outbound = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: target)!, using: .tcp)
            self.kept += [inbound, outbound]
            inbound.start(queue: self.queue)
            outbound.start(queue: self.queue)
            self.pump(from: inbound, to: outbound)
            self.pump(from: outbound, to: inbound)
        }
    }

    func start() async {
        listener.start(queue: queue)
        while listener.port == nil || listener.port?.rawValue == 0 { try? await Task.sleep(for: .milliseconds(20)) }
    }

    func stop() {
        listener.cancel()
        kept.forEach { $0.cancel() }
    }

    private func pump(from: NWConnection, to: NWConnection) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.queue.asyncAfter(deadline: .now() + self.delay) { to.send(content: data, completion: .contentProcessed { _ in }) }
            }
            if !done && error == nil { self.pump(from: from, to: to) }
        }
    }
}

final class RouteProberTests: XCTestCase {
    func testEmptyEndpointsThrowsError() async {
        let prober = RouteProber()
        do {
            _ = try await prober.probeFastest(endpoints: [])
            XCTFail("Expected noEndpointsProvided error")
        } catch let error as RouteProberError {
            XCTAssertEqual(error, .noEndpointsProvided)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testInvalidEndpointsThrowsError() async {
        let prober = RouteProber()
        do {
            _ = try await prober.probeFastest(endpoints: [""])
            XCTFail("Expected noEndpointsProvided error")
        } catch let error as RouteProberError {
            XCTAssertEqual(error, .noEndpointsProvided)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testUnreachableEndpointsThrowsAllEndpointsFailed() async {
        let prober = RouteProber()
        do {
            // Using reserved unroutable addresses with short timeout
            _ = try await prober.probeFastest(
                endpoints: [
                    "ws://192.0.2.1:49999",
                    "ws://198.51.100.1:49999"
                ],
                timeoutSeconds: 0.2
            )
            XCTFail("Expected allEndpointsFailed error")
        } catch let error as RouteProberError {
            XCTAssertEqual(error, .allEndpointsFailed)
        } catch {
            // Socket or POSIX errors during probe
            XCTAssertNotNil(error)
        }
    }

    /// Owner's report (2026-11-22): on a flight the app never connected, though Tailscale worked. Each
    /// round trip took about a second and connecting takes about four, past the old 3-second limit.
    func testASlowLinkStillConnects() async throws {
        let host = try FakeHost()
        try await host.start()
        defer { host.stop() }
        let target = UInt16(URL(string: host.endpoint)!.port!)
        let relay = try SlowRelay(to: target, delay: 0.8)  // 1.6 s per round trip
        await relay.start()
        defer { relay.stop() }
        do {
            _ = try await RouteProber().probeFastest(endpoints: ["ws://127.0.0.1:\(relay.port)"], timeoutSeconds: 3)
            XCTFail("the old 3-second limit gives up on this link")
        } catch {}
        let started = Date()
        let route = try await RouteProber().probeFastest(endpoints: ["ws://127.0.0.1:\(relay.port)"])
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 3.0, "the link really was slow")
        XCTAssertEqual(route.winningURL.port, Int(relay.port))
    }

    /// A long limit costs nothing on a good network: the first route to answer wins.
    func testAFastRouteWinsWithoutWaitingForADeadOne() async throws {
        let host = try FakeHost()
        try await host.start()
        defer { host.stop() }
        let started = Date()
        let route = try await RouteProber().probeFastest(endpoints: ["ws://192.0.2.1:49999", host.endpoint])
        XCTAssertLessThan(Date().timeIntervalSince(started), 3.0)
        XCTAssertEqual(route.winningURL.absoluteString, host.endpoint)
    }

    /// Tailscale polish (docs/tailscale.md): which kind of route each address is.
    func testRoutesAreNamed() {
        XCTAssertEqual(LKRoute.of("wss://100.88.44.108:40225"), .tailscale)
        XCTAssertEqual(LKRoute.of("wss://howeitsdone.tail203404.ts.net:40225"), .tailscale)
        XCTAssertEqual(LKRoute.of("wss://192.168.8.121:40225"), .home)
        XCTAssertEqual(LKRoute.of("wss://10.0.0.5:1"), .home)
        XCTAssertEqual(LKRoute.of("wss://hermes.local:1"), .home)
        XCTAssertEqual(LKRoute.of("wss://my.domain.example:1"), .internet)
        XCTAssertEqual(LKRoute.of("wss://100.200.1.1:1"), .internet, "outside Tailscale's range")
        _ = LKRoute.phoneOnTailscale()  // true here when this Mac is on Tailscale (the simulator shares its network)
    }

    /// A new address from the instance (Tailscale turned on later, a new home IP) is saved: no re-pairing.
    @MainActor
    func testNewAddressesFromTheInstanceAreSaved() async throws {
        let host = try FakeHost()
        host.helloEndpoints = ["wss://100.88.1.2:40225", "wss://box.tail1.ts.net:40225"]
        try await host.start()
        defer { host.stop() }
        let store = InMemoryCredentialStore()
        try SavedHost(instanceId: host.instanceId, instanceName: host.instanceName, deviceId: "dev_1",
                      deviceToken: host.acceptedDeviceToken, endpoints: [host.endpoint],
                      enabledProfileIds: ["default"], activeProfileId: "default").save(to: store)
        let gateway = GatewayClient(keychain: store, requireTLS: false)
        await gateway.resumeSavedSession()
        let saved = await waitUntil { SavedHost.load(from: store)?.endpoints.count == 3 }
        XCTAssertTrue(saved)
        XCTAssertEqual(SavedHost.load(from: store)?.endpoints,
                       [host.endpoint, "wss://100.88.1.2:40225", "wss://box.tail1.ts.net:40225"], "the route in use stays first")
        XCTAssertEqual(gateway.connectedVia, host.endpoint)
    }
}
