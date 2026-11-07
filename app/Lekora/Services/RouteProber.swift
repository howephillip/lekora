import Foundation

public struct RouteProbeResult: Equatable {
    public let winningURL: URL
    public let roundTripMilliseconds: Double
}

public enum RouteProberError: Error, LocalizedError {
    case noEndpointsProvided
    case allEndpointsFailed
    case timeout

    public var errorDescription: String? {
        switch self {
        case .noEndpointsProvided:
            return "No candidate endpoints were provided."
        case .allEndpointsFailed:
            return "Could not reach any host endpoint. Please check your network or Tailscale connection."
        case .timeout:
            return "Connection probe timed out."
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

            do {
                if let winner = try await group.next() {
                    group.cancelAll()
                    return winner
                }
            } catch {
                // If a probe failed, continue checking if other endpoints succeed
                while let result = try? await group.next() {
                    group.cancelAll()
                    return result
                }
            }

            throw RouteProberError.allEndpointsFailed
        }
    }

    private func probeSingle(url: URL, timeoutSeconds: Double) async throws -> RouteProbeResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        let wsTask = session.webSocketTask(with: url)
        wsTask.resume()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
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
