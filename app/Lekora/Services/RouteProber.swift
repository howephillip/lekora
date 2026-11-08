import Foundation

public struct RouteProbeResult: Equatable {
    public let winningURL: URL
    public let roundTripMilliseconds: Double
}

public enum RouteProberError: Error, LocalizedError {
    case noEndpointsProvided
    case allEndpointsFailed
    case timeout
    /// A host answered with a different certificate than the one pinned at pairing.
    case certificateMismatch

    public var errorDescription: String? {
        switch self {
        case .noEndpointsProvided:
            return "No candidate endpoints were provided."
        case .allEndpointsFailed:
            return "Could not reach any host endpoint. Please check your network or Tailscale connection."
        case .timeout:
            return "Connection probe timed out."
        case .certificateMismatch:
            return "The computer that answered isn't the Hermes computer this iPhone was paired with: its security certificate doesn't match. If you reinstalled Lekora on your Hermes computer, pair again with a new code."
        }
    }
}

public actor RouteProber {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Races multiple candidate WebSocket endpoints in parallel and returns the first verified reachable route.
    public func probeFastest(endpoints: [String], timeoutSeconds: Double = 3.0) async throws -> RouteProbeResult {
        guard !endpoints.isEmpty else {
            throw RouteProberError.noEndpointsProvided
        }

        let urls = endpoints.compactMap { URL(string: $0) }
        guard !urls.isEmpty else {
            throw RouteProberError.noEndpointsProvided
        }

        return try await withThrowingTaskGroup(of: RouteProbeResult.self) { group in
            for url in urls {
                group.addTask {
                    try await self.probeSingle(url: url, timeoutSeconds: timeoutSeconds)
                }
            }

            // A failed probe must not stop the race; keep waiting for the others.
            var certificateRejected = false
            while true {
                do {
                    guard let winner = try await group.next() else { break }
                    group.cancelAll()
                    return winner
                } catch {
                    if Self.isCertificateRejection(error) { certificateRejected = true }
                    continue
                }
            }

            throw certificateRejected ? RouteProberError.certificateMismatch : RouteProberError.allEndpointsFailed
        }
    }

    /// A pinned session cancels the TLS challenge when the certificate doesn't match the pin.
    static func isCertificateRejection(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .cancelled, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
             .serverCertificateHasBadDate, .serverCertificateNotYetValid, .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    private func probeSingle(url: URL, timeoutSeconds: Double) async throws -> RouteProbeResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        let wsTask = session.webSocketTask(with: url)
        wsTask.resume()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (rawContinuation: CheckedContinuation<RouteProbeResult, Error>) in
                // Timeout, ping reply and cancellation can all fire; only the first may resume.
                let continuation = ResumeOnce(rawContinuation)
                let timeoutTask = Task {
                    try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                    wsTask.cancel(with: .goingAway, reason: nil)
                    continuation.resume(throwing: RouteProberError.timeout)
                }

                wsTask.sendPing { error in
                    timeoutTask.cancel()
                    let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0

                    if let error = error {
                        wsTask.cancel(with: .goingAway, reason: nil)
                        continuation.resume(throwing: error)
                    } else {
                        // Successfully verified socket communication
                        continuation.resume(returning: RouteProbeResult(winningURL: url, roundTripMilliseconds: elapsedMs))
                    }
                }
            }
        } onCancel: {
            wsTask.cancel(with: .goingAway, reason: nil)
        }
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<RouteProbeResult, Error>?

    init(_ continuation: CheckedContinuation<RouteProbeResult, Error>) {
        self.continuation = continuation
    }

    private func take() -> CheckedContinuation<RouteProbeResult, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let taken = continuation
        continuation = nil
        return taken
    }

    func resume(returning value: RouteProbeResult) { take()?.resume(returning: value) }
    func resume(throwing error: Error) { take()?.resume(throwing: error) }
}
