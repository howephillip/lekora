import Security
import XCTest
@testable import Lekora

/// Encrypted, certificate-pinned connections (plugin/lekora/tls.py).
@MainActor
final class EncryptionTests: XCTestCase {
    /// A certificate made by the plugin's own tls.py, and the fingerprint it printed for it.
    private let testCertificate = Data(base64Encoded: "MIIBRzCB7qADAgECAhAlx+nrSD0ZWdJUjSgjrv1xMAoGCCqGSM49BAMCMB0xGzAZBgNVBAMMEkxla29yYSB0ZXN0IHZlY3RvcjAeFw0yNjExMDcxNzAyMjdaFw00NjExMDMxNzAyMjdaMB0xGzAZBgNVBAMMEkxla29yYSB0ZXN0IHZlY3RvcjBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABNZwiBC2qP5OY/mNZn0DbrKXahzTA+dkaliuYtIzMIFGUnaWC6/OLeHsb0K5dHRFnLi3IgfnZEtFKUydj9Prn5SjEDAOMAwGA1UdEwEB/wQCMAAwCgYIKoZIzj0EAwIDSAAwRQIhALmLttq2yd3e/TyD7HL2Hb9WaD15xuTMIDwVNHSh0NeaAiBLIw5Xi/ZeWgWXUs5/uTPEt+6MVgFMNxHjWJUpaz5ZsA==")!
    private let pluginFingerprint = "W1NG1_jHU_RqeTo4X2mgBYgfm1ckFMfBGeqj1_EjKl8"

    private func trust(for der: Data) throws -> SecTrust {
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, der as CFData))
        var trust: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates(certificate, SecPolicyCreateBasicX509(), &trust), errSecSuccess)
        return try XCTUnwrap(trust)
    }

    // MARK: - Pinning

    func testFingerprintMatchesWhatThePluginComputes() {
        XCTAssertEqual(CertificatePin.fingerprint(ofDER: testCertificate), pluginFingerprint)
    }

    func testOnlyThePinnedCertificateIsAccepted() throws {
        let serverTrust = try trust(for: testCertificate)
        XCTAssertTrue(CertificatePin.matches(serverTrust, pin: pluginFingerprint))
        XCTAssertFalse(CertificatePin.matches(serverTrust, pin: "W1NG1_jHU_RqeTo4X2mgBYgfm1ckFMfBGeqj1_EjKl9"))
        XCTAssertFalse(CertificatePin.matches(serverTrust, pin: ""))
    }

    func testCertificateRejectionIsToldApartFromAnOfflineHost() {
        XCTAssertTrue(RouteProber.isCertificateRejection(URLError(.cancelled)))  // pin mismatch
        XCTAssertTrue(RouteProber.isCertificateRejection(URLError(.serverCertificateUntrusted)))
        XCTAssertFalse(RouteProber.isCertificateRejection(URLError(.cannotConnectToHost)))
        XCTAssertFalse(RouteProber.isCertificateRejection(URLError(.timedOut)))
        XCTAssertTrue(RouteProberError.certificateMismatch.localizedDescription.contains("pair again"))
    }

    // MARK: - Pairing links

    private let encryptedLink = "lekora-pair://pair?token=t&instance_id=inst_1&endpoints=wss%3A%2F%2F192.168.1.2%3A4000%2Cwss%3A%2F%2Fhost.ts.net%3A4000&fp=W1NG1_jHU_RqeTo4X2mgBYgfm1ckFMfBGeqj1_EjKl8"

    func testEncryptedLinkIsAccepted() throws {
        let link = try PairingLink.parse(encryptedLink, requireTLS: true)
        XCTAssertEqual(link.endpoints, ["wss://192.168.1.2:4000", "wss://host.ts.net:4000"])
        XCTAssertEqual(link.certPin, pluginFingerprint)
    }

    func testLinksFromAnOlderUnencryptedPluginAreRefused() {
        let noFingerprint = "lekora-pair://pair?token=t&instance_id=i&endpoints=wss%3A%2F%2Fh%3A1"
        let plainAddress = "lekora-pair://pair?token=t&instance_id=i&endpoints=ws%3A%2F%2Fh%3A1&fp=abc"
        for link in [noFingerprint, plainAddress] {
            XCTAssertThrowsError(try PairingLink.parse(link, requireTLS: true)) { error in
                XCTAssertEqual(error as? PairingLink.ParseError, .notEncrypted)
                XCTAssertTrue(error.localizedDescription.contains("Update the plugin"))
            }
        }
    }

    func testOtherLinkProblemsStillReadable() {
        XCTAssertThrowsError(try PairingLink.parse("https://example.com", requireTLS: true)) {
            XCTAssertEqual($0 as? PairingLink.ParseError, .notALekoraLink)
        }
        XCTAssertThrowsError(try PairingLink.parse("lekora-pair://pair?token=t", requireTLS: true)) {
            XCTAssertEqual($0 as? PairingLink.ParseError, .incomplete)
        }
    }

    func testPastingAnOldLinkShowsTheUpdateMessage() {
        let gateway = GatewayClient(keychain: InMemoryCredentialStore())
        gateway.handlePairingPayload("lekora-pair://pair?token=t&instance_id=i&endpoints=ws%3A%2F%2Fh%3A1")
        guard case .error(let message) = gateway.state else { return XCTFail("expected an error") }
        XCTAssertTrue(message.contains("doesn't encrypt"))
    }

    // MARK: - Saved pairings

    func testPairingFromBeforeEncryptionMustBeRedone() throws {
        let store = InMemoryCredentialStore()
        try SavedHost(instanceId: "i", instanceName: "Hermes", deviceId: "d", deviceToken: "t",
                      endpoints: ["ws://h:1"]).save(to: store)

        let gateway = GatewayClient(keychain: store)

        XCTAssertNil(gateway.savedHost)
        XCTAssertTrue(store.values.isEmpty, "the unusable pairing is removed")
        guard case .error(let message) = gateway.state else { return XCTFail("expected an explanation") }
        XCTAssertTrue(message.contains("pair again"))
    }

    func testEncryptedPairingIsKeptAndRemembersItsPin() throws {
        let store = InMemoryCredentialStore()
        try SavedHost(instanceId: "i", instanceName: "Hermes", deviceId: "d", deviceToken: "t",
                      endpoints: ["wss://h:1"], certPin: pluginFingerprint).save(to: store)
        let gateway = GatewayClient(keychain: store)
        XCTAssertEqual(gateway.savedHost?.certPin, pluginFingerprint)
        XCTAssertEqual(gateway.state, .disconnected)
    }

    func testNeverFallsBackToAnUnencryptedAddress() async throws {
        // A plain ws:// host that would happily answer: the app must not use it.
        let host = try FakeHost()
        try await host.start()
        defer { host.stop() }
        let store = InMemoryCredentialStore()
        try SavedHost(instanceId: host.instanceId, instanceName: "Hermes", deviceId: "dev_1",
                      deviceToken: host.acceptedDeviceToken, endpoints: [host.endpoint],
                      certPin: pluginFingerprint).save(to: store)

        let gateway = GatewayClient(keychain: store)
        await gateway.resumeSavedSession()

        XCTAssertTrue(host.received.isEmpty, "nothing was sent over the unencrypted address")
        guard case .error = gateway.state else { return XCTFail("expected Can't reach") }
    }

    func testPairingWithoutAPinIsRefusedBeforeAnyNetwork() async throws {
        let host = try FakeHost()
        try await host.start()
        defer { host.stop() }
        let gateway = GatewayClient(keychain: InMemoryCredentialStore())
        await gateway.pairAndConnect(pairingToken: host.validPairingToken, instanceId: host.instanceId,
                                     candidateEndpoints: [host.endpoint])
        XCTAssertTrue(host.received.isEmpty)
        XCTAssertNil(gateway.savedHost)
    }

    func testHostThatIsDownIsNotReportedAsADifferentComputer() async throws {
        let session = PinnedSession.make(pin: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
        defer { session.invalidateAndCancel() }
        do {
            _ = try await RouteProber(session: session).probeFastest(endpoints: ["wss://127.0.0.1:9"], timeoutSeconds: 2)
            XCTFail("nothing listens on port 9")
        } catch RouteProberError.certificateMismatch {
            XCTFail("a host that is down must not be called a different computer")
        } catch {
            // expected: unreachable
        }
    }
}
