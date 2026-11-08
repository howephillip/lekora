import Foundation
import Combine

public enum GatewayConnectionState: Equatable {
    case disconnected
    case probing
    case pairing
    case connecting
    case connected(instanceName: String, profileName: String)
    case error(String)
}

@MainActor
public final class GatewayClient: ObservableObject {
    @Published public private(set) var state: GatewayConnectionState = .disconnected
    @Published public private(set) var currentSeq: Int = 0
    @Published public private(set) var timeline = ChatTimeline()
    @Published public private(set) var profiles: [ProfileData] = []

    /// The profile the chat screen talks to. Falls back to the protocol's default profile id.
    public var activeProfileId: String {
        profiles.first?.profile_id ?? "assistant"
    }

    private var webSocketTask: URLSessionWebSocketTask?
    private let session: URLSession
    private let keychain: KeychainManager
    private let prober: RouteProber
    private var heartbeatTimer: Timer?
    private var activeURL: URL?

    public init(
        session: URLSession = .shared,
        keychain: KeychainManager = .shared,
        prober: RouteProber = RouteProber()
    ) {
        self.session = session
        self.keychain = keychain
        self.prober = prober
    }

    public func handlePairingPayload(_ payload: String) {
        // Syntax: lekora-pair://pair?token=<tok>&instance_id=<id>&endpoints=<csv>
        guard let url = URL(string: payload.trimmingCharacters(in: .whitespacesAndNewlines)),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "lekora-pair",
              let queryItems = components.queryItems else {
            state = .error("That isn't a Lekora pairing link. Run the pair command on your Hermes machine again and use the new link.")
            return
        }

        let token = queryItems.first(where: { $0.name == "token" })?.value ?? ""
        let instanceId = queryItems.first(where: { $0.name == "instance_id" })?.value ?? ""
        let endpointsRaw = queryItems.first(where: { $0.name == "endpoints" })?.value ?? ""
        let endpoints = endpointsRaw.components(separatedBy: ",").filter { !$0.isEmpty }

        guard !token.isEmpty, !instanceId.isEmpty, !endpoints.isEmpty else {
            state = .error("The pairing link is incomplete. Run the pair command on your Hermes machine again and use the new link.")
            return
        }

        // Ignore a repeat tap while a pairing attempt is already running (the token is single-use).
        switch state {
        case .probing, .pairing, .connecting:
            return
        default:
            break
        }

        Task {
            await self.pairAndConnect(
                pairingToken: token,
                instanceId: instanceId,
                candidateEndpoints: endpoints
            )
        }
    }

    // MARK: - Pairing & Connection Flow
    public func pairAndConnect(pairingToken: String, instanceId: String, candidateEndpoints: [String]) async {
        state = .probing
        do {
            let probeResult = try await prober.probeFastest(endpoints: candidateEndpoints)
            self.activeURL = probeResult.winningURL

            state = .pairing
            let wsTask = session.webSocketTask(with: probeResult.winningURL)
            self.webSocketTask = wsTask
            wsTask.resume()

            // Construct pair.request
            let pairReq = Envelope(
                type: "pair.request",
                instance_id: instanceId,
                data: PairRequestData(
                    pairing_token: pairingToken,
                    device_name: "iPhone",
                    client_version: "1.0.0"
                )
            )

            let encoder = JSONEncoder()
            let reqData = try encoder.encode(pairReq)
            guard let reqString = String(data: reqData, encoding: .utf8) else {
                state = .error("Failed to serialize pair request.")
                return
            }

            try await wsTask.send(.string(reqString))

            // Wait for pair.response
            let message = try await wsTask.receive()
            switch message {
            case .string(let text):
                guard let data = text.data(using: .utf8) else {
                    state = .error("Invalid text payload from host.")
                    return
                }

                let responseEnvelope = try JSONDecoder().decode(Envelope<PairResponseData>.self, from: data)
                if responseEnvelope.data.status == "ok" {
                    // Save credentials in Keychain
                    try keychain.save(key: "device_token", value: responseEnvelope.data.device_token)
                    try keychain.save(key: "device_id", value: responseEnvelope.data.device_id)
                    try keychain.save(key: "instance_id", value: instanceId)
                    try keychain.save(key: "instance_name", value: responseEnvelope.data.instance_name)

                    // Transition to hello handshake
                    await completeSessionHandshake(
                        wsTask: wsTask,
                        instanceId: instanceId,
                        deviceId: responseEnvelope.data.device_id,
                        deviceToken: responseEnvelope.data.device_token
                    )
                } else {
                    state = .error("Pairing rejected by host.")
                }
            case .data:
                state = .error("Unexpected binary message during pairing.")
            @unknown default:
                state = .error("Unknown message type.")
            }
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    public func reconnect(candidateEndpoints: [String]) async {
        guard let deviceToken = try? keychain.get(key: "device_token"),
              let deviceId = try? keychain.get(key: "device_id"),
              let instanceId = try? keychain.get(key: "instance_id") else {
            state = .error("No saved device credentials found in Keychain.")
            return
        }

        state = .probing
        do {
            let probeResult = try await prober.probeFastest(endpoints: candidateEndpoints)
            self.activeURL = probeResult.winningURL

            state = .connecting
            let wsTask = session.webSocketTask(with: probeResult.winningURL)
            self.webSocketTask = wsTask
            wsTask.resume()

            await completeSessionHandshake(
                wsTask: wsTask,
                instanceId: instanceId,
                deviceId: deviceId,
                deviceToken: deviceToken
            )
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    private func completeSessionHandshake(
        wsTask: URLSessionWebSocketTask,
        instanceId: String,
        deviceId: String,
        deviceToken: String
    ) async {
        do {
            let helloEnvelope = Envelope(
                type: "hello",
                instance_id: instanceId,
                data: HelloData(
                    device_id: deviceId,
                    device_token: deviceToken,
                    last_seq: currentSeq,
                    client_version: "1.0.0",
                    proto_version: 1
                )
            )

            let helloData = try JSONEncoder().encode(helloEnvelope)
            guard let helloString = String(data: helloData, encoding: .utf8) else {
                state = .error("Serialization failure during handshake.")
                return
            }

            try await wsTask.send(.string(helloString))

            let message = try await wsTask.receive()
            if case .string(let text) = message,
               let data = text.data(using: .utf8) {
                let ackEnvelope = try JSONDecoder().decode(Envelope<HelloAckData>.self, from: data)
                if ackEnvelope.data.status == "ok" {
                    self.currentSeq = ackEnvelope.data.current_seq
                    self.profiles = ackEnvelope.data.profiles
                    let primaryProfileName = ackEnvelope.data.profiles.first?.name ?? "Hermes Agent"
                    state = .connected(instanceName: ackEnvelope.data.instance_name, profileName: primaryProfileName)

                    startHeartbeat()
                    startReceiveLoop(wsTask: wsTask)
                } else {
                    state = .error("Handshake rejected by host.")
                }
            } else {
                state = .error("Invalid handshake response format.")
            }
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    // MARK: - Chat
    public nonisolated static func makeChatSendEnvelope(text: String, instanceId: String, profileId: String) -> Envelope<ChatSendData> {
        Envelope(
            type: "chat.send",
            instance_id: instanceId,
            profile_id: profileId,
            data: ChatSendData(text: text)
        )
    }

    /// Sends `text` to the active profile. The message appears in the timeline straight
    /// away; a failed send is marked on that bubble instead of dropping the connection.
    public func sendMessage(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              case .connected = state,
              let wsTask = webSocketTask,
              let instanceId = try? keychain.get(key: "instance_id") else {
            return
        }

        let envelope = Self.makeChatSendEnvelope(text: trimmed, instanceId: instanceId, profileId: activeProfileId)
        timeline.addOutgoing(id: envelope.id, profileId: activeProfileId, text: trimmed)

        do {
            let data = try JSONEncoder().encode(envelope)
            guard let string = String(data: data, encoding: .utf8) else {
                timeline.markFailed(id: envelope.id, reason: "Couldn't prepare the message.")
                return
            }
            try await wsTask.send(.string(string))
            timeline.markSent(id: envelope.id)
        } catch {
            timeline.markFailed(id: envelope.id, reason: error.localizedDescription)
        }
    }

    /// Connection check used by the walking-skeleton tests.
    public func sendPing() async {
        await sendMessage("Ping")
    }

    /// Applies one host text frame to the timeline. Unknown types are ignored.
    func handleIncoming(_ data: Data) {
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(EnvelopeHeader.self, from: data) else { return }

        switch header.type {
        case "chat.message":
            guard let envelope = try? decoder.decode(Envelope<ChatMessageData>.self, from: data) else { return }
            currentSeq = max(currentSeq, envelope.data.seq)
            timeline.applyIncoming(
                seq: envelope.data.seq,
                profileId: envelope.profile_id ?? activeProfileId,
                role: envelope.data.role,
                text: envelope.data.text
            )
        case "error":
            guard let envelope = try? decoder.decode(Envelope<ErrorData>.self, from: data) else { return }
            // Errors about a chat.send reuse that message's id.
            timeline.markFailed(id: envelope.id, reason: envelope.data.reason)
        default:
            break
        }
    }

    // MARK: - Background Receive Loop
    private func startReceiveLoop(wsTask: URLSessionWebSocketTask) {
        Task { [weak self] in
            while true {
                do {
                    let message = try await wsTask.receive()
                    guard let self = self else { break }

                    if case .string(let text) = message,
                       let data = text.data(using: .utf8) {
                        self.handleIncoming(data)
                    }
                } catch {
                    await MainActor.run { [weak self] in
                        self?.handleDisconnection()
                    }
                    break
                }
            }
        }
    }

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.webSocketTask?.sendPing { _ in }
            }
        }
    }

    private func handleDisconnection() {
        heartbeatTimer?.invalidate()
        state = .disconnected
    }

    public func disconnect() {
        heartbeatTimer?.invalidate()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        state = .disconnected
    }
}
