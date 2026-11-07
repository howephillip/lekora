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
    @Published public private(set) var receivedMessages: [ChatMessageData] = []
    @Published public private(set) var profiles: [ProfileData] = []

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

    // MARK: - Walking Skeleton Chat Transmission
    public func sendPing() async {
        guard case .connected = state,
              let wsTask = webSocketTask,
              let instanceId = try? keychain.get(key: "instance_id") else {
            return
        }

        let targetProfile = profiles.first?.profile_id ?? "assistant"
        let pingEnvelope = Envelope(
            type: "chat.send",
            instance_id: instanceId,
            profile_id: targetProfile,
            data: ChatSendData(text: "Ping")
        )

        do {
            let data = try JSONEncoder().encode(pingEnvelope)
            if let string = String(data: data, encoding: .utf8) {
                try await wsTask.send(.string(string))
            }
        } catch {
            state = .error("Failed to send ping: \(error.localizedDescription)")
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
                        if let chatEnvelope = try? JSONDecoder().decode(Envelope<ChatMessageData>.self, from: data),
                           chatEnvelope.type == "chat.message" {
                            await MainActor.run {
                                self.currentSeq = max(self.currentSeq, chatEnvelope.data.seq)
                                self.receivedMessages.append(chatEnvelope.data)
                            }
                        }
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
