import CryptoKit
import Foundation
import Security

/// Certificate pinning for the host's self-made certificate (see plugin/lekora/tls.py).
///
/// The pairing code carries the certificate's fingerprint: base64url(SHA-256(DER)),
/// no padding. The app accepts that one certificate only; a different certificate is
/// refused even if a public authority signed it. This is what makes `wss://` safe on
/// home Wi-Fi as well as Tailscale, with no domain or account.
public enum CertificatePin {
    public static func fingerprint(ofDER der: Data) -> String {
        Data(SHA256.hash(data: der)).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// True when the server's own (leaf) certificate has the pinned fingerprint.
    public static func matches(_ trust: SecTrust, pin: String) -> Bool {
        guard !pin.isEmpty,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            return false
        }
        let der = SecCertificateCopyData(leaf) as Data
        return fingerprint(ofDER: der) == pin
    }
}

/// Accepts the server only if its certificate matches the pin; everything else is cancelled.
final class PinnedTLSDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let pin: String

    init(pin: String) {
        self.pin = pin
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        evaluate(challenge, completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        evaluate(challenge, completionHandler)
    }

    private func evaluate(_ challenge: URLAuthenticationChallenge,
                          _ completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if CertificatePin.matches(trust, pin: pin) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

public enum PinnedSession {
    /// A session for one host: pinned when a fingerprint is known (always, in the app).
    public static func make(pin: String?) -> URLSession {
        guard let pin, !pin.isEmpty else { return URLSession(configuration: .default) }
        return URLSession(configuration: .default, delegate: PinnedTLSDelegate(pin: pin), delegateQueue: nil)
    }
}

/// A parsed `lekora-pair://pair?token=…&instance_id=…&endpoints=…&fp=…` link.
public struct PairingLink: Equatable {
    public let token: String
    public let instanceId: String
    public let endpoints: [String]
    public let certPin: String?

    public enum ParseError: Error, LocalizedError, Equatable {
        case notALekoraLink
        case incomplete
        case notEncrypted

        public var errorDescription: String? {
            switch self {
            case .notALekoraLink:
                return "That isn't a Lekora pairing link. Run the pair command on your Hermes machine again and use the new link."
            case .incomplete:
                return "The pairing link is incomplete. Run the pair command on your Hermes machine again and use the new link."
            case .notEncrypted:
                return "This pairing code comes from an older Lekora on your Hermes computer that doesn't encrypt the connection. Update the plugin there (hermes plugins install howephillip/lekora#plugin/lekora --enable, then hermes gateway restart) and make a new code."
            }
        }
    }

    /// `requireTLS`: only encrypted (`wss://`) addresses with a certificate fingerprint are accepted.
    public static func parse(_ payload: String, requireTLS: Bool) throws -> PairingLink {
        guard let url = URL(string: payload.trimmingCharacters(in: .whitespacesAndNewlines)),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "lekora-pair",
              let items = components.queryItems else {
            throw ParseError.notALekoraLink
        }
        func value(_ name: String) -> String {
            items.first(where: { $0.name == name })?.value ?? ""
        }
        let endpoints = value("endpoints").components(separatedBy: ",").filter { !$0.isEmpty }
        guard !value("token").isEmpty, !value("instance_id").isEmpty, !endpoints.isEmpty else {
            throw ParseError.incomplete
        }
        let pin = value("fp")
        if requireTLS {
            guard !pin.isEmpty, endpoints.allSatisfy({ $0.lowercased().hasPrefix("wss://") }) else {
                throw ParseError.notEncrypted
            }
        }
        return PairingLink(token: value("token"), instanceId: value("instance_id"),
                           endpoints: endpoints, certPin: pin.isEmpty ? nil : pin)
    }
}
