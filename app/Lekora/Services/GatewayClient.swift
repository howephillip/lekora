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

/// An `error` envelope from the host, surfaced as a Swift error.
public struct HostError: Error, LocalizedError, Equatable {
    public let code: String
    public let reason: String

    public var errorDescription: String? { reason }

    /// The host no longer accepts this phone's device token (revoked, or the host's data was reset).
    public var meansCredentialsInvalid: Bool { code == "AUTH_FAILED" }
}

@MainActor
public final class GatewayClient: ObservableObject {
    @Published public private(set) var state: GatewayConnectionState = .disconnected
    @Published public private(set) var currentSeq: Int = 0
    @Published public private(set) var timeline = ChatTimeline()
    @Published public private(set) var profiles: [ProfileData] = []
    /// The paired host, if any. While set, the app reconnects instead of showing the setup wizard.
    @Published public private(set) var savedHost: SavedHost?

    /// The agent the chat screen talks to; `chat.send` goes to this profile.
    @Published public private(set) var activeProfileId: String = "default"

    /// The host's agents that this phone uses, in the host's order.
    public var enabledProfiles: [ProfileData] {
        guard let chosen = savedHost?.enabledProfileIds else { return [] }
        return profiles.filter { chosen.contains($0.profile_id) }
    }

    public var activeProfile: ProfileData? {
        profiles.first { $0.profile_id == activeProfileId }
    }

    /// True when connected but no usable agent has been chosen yet: show "Choose Agents".
    public var needsProfileChoice: Bool {
        guard case .connected = state else { return false }
        return enabledProfiles.isEmpty
    }

    private var webSocketTask: URLSessionWebSocketTask?
    private let keychain: CredentialStore
    /// Only encrypted (`wss://`), certificate-pinned connections. Off only in tests
    /// that talk to the plain local fake host.
    private let requireTLS: Bool
    /// Makes a URLSession for a host; pinned to its certificate when a pin is given.
    private let sessionFactory: (String?) -> URLSession
    /// The session of the current connection (pinned to the host's certificate).
    private var currentSession: URLSession?
    private var heartbeatTimer: Timer?
    private var activeURL: URL?
    /// Requests awaiting a reply with the same envelope id (agent create/delete).
    private var pendingReplies: [String: CheckedContinuation<Data, Error>] = [:]

    public init(
        keychain: CredentialStore = KeychainManager.shared,
        requireTLS: Bool = true,
        sessionFactory: @escaping (String?) -> URLSession = { PinnedSession.make(pin: $0) }
    ) {
        self.keychain = keychain
        self.requireTLS = requireTLS
        self.sessionFactory = sessionFactory
        let saved = SavedHost.load(from: keychain)
        if requireTLS, let saved, saved.certPin == nil {
            // Paired before connections were encrypted: that pairing can't be used any more.
            SavedHost.clear(from: keychain)
            self.savedHost = nil
            self.state = .error("Lekora now encrypts the connection to \(saved.instanceName), so this iPhone needs to pair again. On your Hermes computer, run hermes lekora pair and scan the new code.")
        } else {
            self.savedHost = saved
        }
    }

    /// A fresh session for the next connection, pinned to `pin`; the previous one is released.
    private func connectionSession(pin: String?) -> URLSession {
        currentSession?.invalidateAndCancel()
        let session = sessionFactory(pin)
        currentSession = session
        return session
    }

    /// With TLS required, only encrypted addresses are ever tried.
    private func usable(_ endpoints: [String]) -> [String] {
        requireTLS ? endpoints.filter { $0.lowercased().hasPrefix("wss://") } : endpoints
    }

    private var isBusy: Bool {
        switch state {
        case .probing, .pairing, .connecting, .connected:
            return true
        default:
            return false
        }
    }

    public func handlePairingPayload(_ payload: String) {
        // lekora-pair://pair?token=<tok>&instance_id=<id>&endpoints=<csv>&fp=<cert fingerprint>
        let link: PairingLink
        do {
            link = try PairingLink.parse(payload, requireTLS: requireTLS)
        } catch {
            state = .error(error.localizedDescription)
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
                pairingToken: link.token,
                instanceId: link.instanceId,
                candidateEndpoints: link.endpoints,
                certPin: link.certPin
            )
        }
    }

    // MARK: - Pairing & Connection Flow
    public func pairAndConnect(pairingToken: String, instanceId: String, candidateEndpoints: [String],
                               certPin: String? = nil) async {
        // A new pairing replaces whatever this phone was connected to before.
        closeSocket()
        resetSessionData()
        state = .probing
        do {
            if requireTLS, certPin == nil {
                throw PairingLink.ParseError.notEncrypted
            }
            let session = connectionSession(pin: certPin)
            let probeResult = try await RouteProber(session: session).probeFastest(endpoints: usable(candidateEndpoints))
            self.activeURL = probeResult.winningURL

            state = .pairing
            let wsTask = openSocket(to: probeResult.winningURL, session: session)

            let pairReq = Envelope(
                type: "pair.request",
                instance_id: instanceId,
                data: PairRequestData(
                    pairing_token: pairingToken,
                    device_name: DeviceName.current,
                    client_version: "1.0.0"
                )
            )
            try await send(pairReq, on: wsTask)

            let response = try await receiveReply(PairResponseData.self, on: wsTask)
            guard response.status == "ok" else {
                state = .error("Pairing rejected by host.")
                return
            }

            let host = SavedHost(
                instanceId: instanceId,
                instanceName: response.instance_name,
                deviceId: response.device_id,
                deviceToken: response.device_token,
                endpoints: usable(SavedHost.orderedEndpoints(
                    preferred: probeResult.winningURL, response.endpoints, candidateEndpoints)),
                certPin: certPin
            )
            try host.save(to: keychain)
            savedHost = host

            await completeSessionHandshake(wsTask: wsTask, host: host)
        } catch {
            closeSocket()
            state = .error(error.localizedDescription)
        }
    }

    /// Reconnects to the saved host, if there is one. Safe to call repeatedly: does
    /// nothing while a connection attempt is running or already connected.
    public func resumeSavedSession() async {
        guard let host = savedHost else { return }
        guard !isBusy, !isForgetting else { return }

        state = .probing
        do {
            let session = connectionSession(pin: host.certPin)
            let probeResult = try await RouteProber(session: session).probeFastest(endpoints: usable(host.endpoints))
            self.activeURL = probeResult.winningURL

            state = .connecting
            let wsTask = openSocket(to: probeResult.winningURL, session: session)
            await completeSessionHandshake(wsTask: wsTask, host: host)
        } catch RouteProberError.certificateMismatch {
            closeSocket()
            state = .error(RouteProberError.certificateMismatch.localizedDescription)
        } catch {
            closeSocket()
            state = .error("Can't reach \(host.instanceName) right now. Check that the computer is on and that this phone is on the same network or Tailscale.")
        }
    }

    private func completeSessionHandshake(wsTask: URLSessionWebSocketTask, host: SavedHost) async {
        do {
            // On a fresh launch currentSeq is 0, so the host replays the conversation;
            // after a dropped connection it is the last seq seen, so only new messages come.
            let helloEnvelope = Envelope(
                type: "hello",
                instance_id: host.instanceId,
                data: HelloData(
                    device_id: host.deviceId,
                    device_token: host.deviceToken,
                    last_seq: currentSeq,
                    client_version: "1.0.0",
                    proto_version: 1
                )
            )
            try await send(helloEnvelope, on: wsTask)

            let ack = try await receiveReply(HelloAckData.self, on: wsTask)
            guard ack.status == "ok" else {
                closeSocket()
                state = .error("Handshake rejected by host.")
                return
            }

            self.profiles = ack.profiles
            reconcileProfileChoice()
            let activeName = activeProfile?.name ?? ack.profiles.first?.name ?? "Hermes Agent"
            state = .connected(instanceName: ack.instance_name, profileName: activeName)

            startHeartbeat()
            startReceiveLoop(wsTask: wsTask)
        } catch let hostError as HostError where hostError.meansCredentialsInvalid {
            // The host no longer knows this phone: forget it so the wizard shows.
            forgetLocally()
            state = .error("This phone is no longer paired with \(host.instanceName). Run the pair command on your Hermes machine and scan the new code.")
        } catch {
            closeSocket()
            state = .error(error.localizedDescription)
        }
    }

    public enum ForgetOutcome: Equatable {
        /// The host revoked this phone (or had already), so nothing is left behind.
        case removedFromHost
        /// Forgotten on the phone only; the host still lists it until revoked there.
        case hostUnreachable
    }

    /// "Forget Host": asks the host to revoke this phone, then clears the saved host
    /// and returns to the setup wizard. The phone forgets the host even when the host
    /// can't be reached; the setup screen then says how to clean up on the host.
    @discardableResult
    public func forgetHost() async -> ForgetOutcome {
        guard let host = savedHost, !isForgetting else { return .removedFromHost }
        isForgetting = true
        defer { isForgetting = false }

        // Stop the chat socket first so nothing else arrives while forgetting.
        closeSocket()
        let preferred = activeURL.map { [$0.absoluteString] } ?? []
        let outcome = await requestUnpair(host: host, endpoints: SavedHost.orderedEndpoints(preferred: nil, preferred, host.endpoints))

        forgetLocally()
        if outcome == .hostUnreachable {
            state = .error("This phone forgot \(host.instanceName), but couldn't reach it to remove this phone from its list. On the Hermes machine, `hermes lekora devices` can revoke it.")
        }
        return outcome
    }

    /// True while Forget Host is talking to the host.
    @Published public private(set) var isForgetting = false

    /// Sends `device.unpair` on its own short-lived socket. Never throws: any failure
    /// other than "already revoked" counts as unreachable.
    private func requestUnpair(host: SavedHost, endpoints: [String]) async -> ForgetOutcome {
        var unpairSocket: URLSessionWebSocketTask?
        let session = sessionFactory(host.certPin)  // its own pinned session
        defer {
            unpairSocket?.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }
        do {
            let route = try await RouteProber(session: session).probeFastest(endpoints: usable(endpoints), timeoutSeconds: 2)
            let wsTask = session.webSocketTask(with: route.winningURL)
            unpairSocket = wsTask
            wsTask.resume()

            let request = Envelope(
                type: "device.unpair",
                instance_id: host.instanceId,
                data: DeviceUnpairData(device_id: host.deviceId, device_token: host.deviceToken)
            )
            try await send(request, on: wsTask)
            _ = try await withTimeout(seconds: 3) {
                try await self.receiveReply(DeviceUnpairAckData.self, on: wsTask)
            }
            return .removedFromHost
        } catch let hostError as HostError where hostError.meansCredentialsInvalid {
            return .removedFromHost  // already revoked on the host
        } catch {
            return .hostUnreachable
        }
    }

    private func withTimeout<T: Sendable>(seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw RouteProberError.timeout
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw RouteProberError.timeout }
            return first
        }
    }

    /// Clears the saved host and everything shown for it, without contacting the host.
    private func forgetLocally() {
        closeSocket()
        SavedHost.clear(from: keychain)
        savedHost = nil
        resetSessionData()
        state = .disconnected
    }

    private func resetSessionData() {
        timeline = ChatTimeline()
        profiles = []
        currentSeq = 0
        activeProfileId = "default"
    }

    // MARK: - Agents (profiles)

    /// Keeps the saved choice in step with the host's current profiles: drops agents that
    /// no longer exist, picks the only agent automatically, and keeps a valid active agent.
    private func reconcileProfileChoice() {
        guard var host = savedHost else { return }
        let available = profiles.map(\.profile_id)

        if let chosen = host.enabledProfileIds {
            host.enabledProfileIds = available.filter { chosen.contains($0) }
        } else if available.count == 1 {
            host.enabledProfileIds = available  // nothing to choose
        }
        let enabled = host.enabledProfileIds ?? []
        if let active = host.activeProfileId, enabled.contains(active) {
            activeProfileId = active
        } else if let first = enabled.first {
            activeProfileId = first
        } else {
            activeProfileId = available.first ?? "default"
        }
        host.activeProfileId = enabled.isEmpty ? nil : activeProfileId
        persistProfileChoice(host)
    }

    /// Sets which agents this phone uses (host order is kept). Ignores unknown ids;
    /// an empty choice is not allowed.
    public func chooseProfiles(_ ids: [String]) {
        guard var host = savedHost else { return }
        let chosen = profiles.map(\.profile_id).filter { ids.contains($0) }
        guard !chosen.isEmpty else { return }
        host.enabledProfileIds = chosen
        if !chosen.contains(activeProfileId) {
            activeProfileId = chosen[0]
        }
        host.activeProfileId = activeProfileId
        persistProfileChoice(host)
    }

    /// Shows another chosen agent's conversation; new messages go to it.
    public func switchToProfile(_ id: String) {
        guard var host = savedHost, enabledProfiles.contains(where: { $0.profile_id == id }) else { return }
        activeProfileId = id
        host.activeProfileId = id
        persistProfileChoice(host)
    }

    /// New agent list from the host (another phone created or deleted one).
    private func applyProfiles(_ newProfiles: [ProfileData]) {
        let removed = Set(profiles.map(\.profile_id)).subtracting(newProfiles.map(\.profile_id))
        profiles = newProfiles
        for id in removed { timeline.removeEntries(for: id) }
        reconcileProfileChoice()
    }

    /// Creates an agent on the host (a clone of the default agent's settings). If this phone
    /// already has a choice, the new agent is switched on and becomes the current chat.
    @discardableResult
    public func createProfile(name: String, description: String? = nil) async throws -> ProfileData {
        let trimmed = description?.trimmingCharacters(in: .whitespacesAndNewlines)
        let ack = try await request(
            type: "profile.create",
            data: ProfileCreateData(name: name, description: (trimmed?.isEmpty ?? true) ? nil : trimmed),
            reply: ProfileCreateAckData.self, timeout: 200)
        let created = ack.profile
        if !profiles.contains(where: { $0.profile_id == created.profile_id }) {
            profiles.append(created)
        }
        if let enabled = savedHost?.enabledProfileIds, !enabled.isEmpty {
            chooseProfiles(enabled + [created.profile_id])
            switchToProfile(created.profile_id)
        }
        return created
    }

    /// Deletes an agent on the host. The host backs it up first and refuses `default`.
    /// Returns the backup's location on the host.
    @discardableResult
    public func deleteProfile(_ profileId: String) async throws -> String {
        let ack = try await request(
            type: "profile.delete",
            data: ProfileDeleteData(profile_id: profileId, confirm: profileId),
            reply: ProfileDeleteAckData.self, timeout: 200)
        applyProfiles(profiles.filter { $0.profile_id != profileId })
        return ack.backup
    }

    private func request<T: Codable, R: Codable>(type: String, data: T, reply: R.Type, timeout: Double) async throws -> R {
        guard case .connected = state, let wsTask = webSocketTask, let instanceId = savedHost?.instanceId else {
            throw HostError(code: "DISCONNECTED", reason: "Not connected to the host.")
        }
        let envelope = Envelope(type: type, instance_id: instanceId, data: data)
        let raw: Data = try await withCheckedThrowingContinuation { continuation in
            pendingReplies[envelope.id] = continuation
            Task { [weak self] in
                do {
                    try await self?.send(envelope, on: wsTask)
                } catch {
                    self?.resolvePending(envelope.id, .failure(error))
                }
            }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.resolvePending(envelope.id, .failure(HostError(code: "TIMEOUT", reason: "The host didn't answer in time.")))
            }
        }
        return try JSONDecoder().decode(Envelope<R>.self, from: raw).data
    }

    private func resolvePending(_ id: String, _ result: Result<Data, Error>) {
        pendingReplies.removeValue(forKey: id)?.resume(with: result)
    }

    private func persistProfileChoice(_ host: SavedHost) {
        try? host.saveProfileChoice(to: keychain)
        savedHost = host
    }

    // MARK: - Socket helpers
    private func openSocket(to url: URL, session: URLSession) -> URLSessionWebSocketTask {
        let wsTask = session.webSocketTask(with: url)
        webSocketTask = wsTask
        wsTask.resume()
        return wsTask
    }

    private func send<T: Codable>(_ envelope: Envelope<T>, on wsTask: URLSessionWebSocketTask) async throws {
        let data = try JSONEncoder().encode(envelope)
        guard let string = String(data: data, encoding: .utf8) else {
            throw HostError(code: "CLIENT", reason: "Couldn't prepare a message for the host.")
        }
        try await wsTask.send(.string(string))
    }

    /// Reads the next frame as `T`, turning a host `error` envelope into `HostError`.
    private func receiveReply<T: Codable>(_ type: T.Type, on wsTask: URLSessionWebSocketTask) async throws -> T {
        let message = try await wsTask.receive()
        guard case .string(let text) = message, let data = text.data(using: .utf8) else {
            throw HostError(code: "CLIENT", reason: "The host sent an unexpected reply.")
        }
        let decoder = JSONDecoder()
        if let header = try? decoder.decode(EnvelopeHeader.self, from: data), header.type == "error",
           let errorEnvelope = try? decoder.decode(Envelope<ErrorData>.self, from: data) {
            throw HostError(code: errorEnvelope.data.code, reason: errorEnvelope.data.reason)
        }
        return try decoder.decode(Envelope<T>.self, from: data).data
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
              let instanceId = savedHost?.instanceId else {
            return
        }

        let envelope = Self.makeChatSendEnvelope(text: trimmed, instanceId: instanceId, profileId: activeProfileId)
        timeline.addOutgoing(id: envelope.id, profileId: activeProfileId, text: trimmed)

        do {
            try await send(envelope, on: wsTask)
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

        // A reply (or error) to a pending request, e.g. profile.create.ack.
        if pendingReplies[header.id] != nil {
            if header.type == "error", let envelope = try? decoder.decode(Envelope<ErrorData>.self, from: data) {
                resolvePending(header.id, .failure(HostError(code: envelope.data.code, reason: envelope.data.reason)))
            } else {
                resolvePending(header.id, .success(data))
            }
            return
        }

        switch header.type {
        case "profiles.changed":
            guard let envelope = try? decoder.decode(Envelope<ProfilesChangedData>.self, from: data) else { return }
            applyProfiles(envelope.data.profiles)
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
                    // Only the current socket may change state: an old socket that dies
                    // after a reconnect must not knock the new connection offline.
                    if let self, self.webSocketTask === wsTask {
                        self.handleDisconnection()
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
        failPendingReplies()
        heartbeatTimer?.invalidate()
        webSocketTask = nil
        state = .disconnected
    }

    private func failPendingReplies() {
        for id in Array(pendingReplies.keys) {
            resolvePending(id, .failure(HostError(code: "DISCONNECTED", reason: "The connection to the host was lost.")))
        }
    }

    private func closeSocket() {
        failPendingReplies()
        heartbeatTimer?.invalidate()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
    }

    /// Drops the connection but keeps the saved host, so the app can reconnect later.
    public func disconnect() {
        closeSocket()
        state = .disconnected
    }
}
