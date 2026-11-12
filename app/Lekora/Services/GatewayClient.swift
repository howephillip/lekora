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
    @Published public private(set) var timeline = ChatTimeline() {
        didSet { if timeline != oldValue { cacheChanged() } }
    }
    /// Highest change number seen (docs/chat-history.md); the next `hello` asks for what
    /// changed after it.
    private var currentRev: Int = 0
    /// Each agent's read marker (highest seq read, on any of the user's phones).
    @Published public private(set) var readMarkers: [String: Int] = [:]
    /// False with hosts from before read markers: then no unread dots are shown.
    @Published public private(set) var hostTracksRead = false
    /// Agents whose older messages are being fetched right now.
    @Published public private(set) var loadingOlder: Set<String> = []
    /// True while the chat is on screen with the app in front: new messages count as read.
    private var chatVisible = false
    @Published public private(set) var profiles: [ProfileData] = []
    /// The paired host, if any. While set, the app reconnects instead of showing the setup wizard.
    @Published public private(set) var savedHost: SavedHost?

    /// Agents currently working (profile id -> what they're doing). Cleared when the host
    /// says they've stopped, or when it goes quiet for `activityTimeout` seconds.
    @Published public private(set) var agentActivity: [String: AgentActivity] = [:]
    /// Hermes pings every ~2 s while an agent works; 3 missed pings means it's done.
    var activityTimeout: TimeInterval = 6

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
    /// Where chats are kept between launches; nil = memory only (most tests).
    private let cacheStore: ChatCacheStore?
    private var cacheSaveTask: Task<Void, Never>?

    /// Which paired computer a client is for (docs/multiple-instances.md).
    public enum Start {
        /// The first paired computer (one-computer code and tests).
        case firstSaved
        /// This paired computer.
        case saved(SavedHost)
        /// None yet: for pairing a new computer.
        case fresh
    }

    public init(
        keychain: CredentialStore = KeychainManager.shared,
        requireTLS: Bool = true,
        sessionFactory: @escaping (String?) -> URLSession = { PinnedSession.make(pin: $0) },
        cacheStore: ChatCacheStore? = nil,
        start: Start = .firstSaved
    ) {
        self.keychain = keychain
        self.requireTLS = requireTLS
        self.sessionFactory = sessionFactory
        self.cacheStore = cacheStore
        let saved: SavedHost?
        switch start {
        case .firstSaved: saved = SavedHost.load(from: keychain)
        case .saved(let host): saved = host
        case .fresh: saved = nil
        }
        if requireTLS, let saved, saved.certPin == nil {
            // Paired before connections were encrypted: that pairing can't be used any more.
            SavedHost.clear(instanceId: saved.instanceId, from: keychain)
            self.savedHost = nil
            self.state = .error("Lekora now encrypts the connection to \(saved.instanceName), so this iPhone needs to pair again. On your Hermes computer, run hermes lekora pair and scan the new code.")
        } else {
            self.savedHost = saved
            if let saved { loadCache(for: saved) }
        }
    }

    // MARK: - Cache (docs/chat-history.md)

    /// Shows the last known chats straight away, before the host answers.
    private func loadCache(for host: SavedHost) {
        guard let cache = cacheStore?.load(instanceId: host.instanceId) else { return }
        timeline = ChatTimeline(entries: cache.entries, completeProfiles: Set(cache.completeProfiles))
        currentRev = cache.rev
        currentSeq = cache.lastSeq
        readMarkers = cache.read
        hostTracksRead = cache.hostTracksRead
        profiles = cache.profiles
        activeProfileId = host.activeProfileId ?? cache.profiles.first?.profile_id ?? "default"
    }

    /// Saves soon (at most about once a second while things change).
    private func cacheChanged() {
        guard cacheStore != nil, cacheSaveTask == nil else { return }
        cacheSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            self?.cacheSaveTask = nil
            self?.saveCacheNow()
        }
    }

    /// Writes the cache now (also called when the app goes to the background).
    public func saveCacheNow() {
        guard let cacheStore, let host = savedHost else { return }
        let kept = timeline.cacheSnapshot(perProfile: ChatCache.messagesPerAgent)
        cacheStore.save(ChatCache(
            instanceId: host.instanceId, rev: currentRev, lastSeq: currentSeq,
            entries: kept.entries, completeProfiles: Array(kept.completeProfiles).sorted(),
            read: readMarkers, hostTracksRead: hostTracksRead, profiles: profiles))
    }

    /// True when a host is paired and some of its chats are known (shown while reconnecting).
    public var hasCachedChats: Bool {
        savedHost != nil && !profiles.isEmpty && !(savedHost?.enabledProfileIds ?? []).isEmpty
    }

    // MARK: - Unread (docs/chat-history.md)

    /// An agent has replies newer than its read marker.
    public func hasUnread(_ profileId: String) -> Bool {
        guard hostTracksRead else { return false }
        let marker = readMarkers[profileId] ?? 0
        return timeline.entries.contains {
            $0.profileId == profileId && ($0.role == .agent || $0.role == .prompt) && ($0.seq ?? 0) > marker
        }
    }

    /// Another agent this phone uses has unread replies.
    public var otherAgentsHaveUnread: Bool { otherAgentsWithUnread > 0 }

    /// How many other agents have unread replies (the count by the chat's back button).
    public var otherAgentsWithUnread: Int {
        enabledProfiles.filter { $0.profile_id != activeProfileId && hasUnread($0.profile_id) }.count
    }

    /// Each agent's avatar colours, unique among the host's agents (and, while there are
    /// colours left, different from the agents of computers paired earlier).
    public var avatarPalettes: [String: Int] {
        LKAgentLook.assignPalettes(profiles.map(\.profile_id), avoiding: palettesTakenElsewhere())
    }

    /// Called once pairing succeeded and the computer is saved (`HostsModel` adds it).
    var onPaired: ((GatewayClient) -> Void)?

    /// Colours used by the agents of computers paired before this one (set by `HostsModel`).
    var palettesTakenElsewhere: () -> Set<Int> = { [] }

    /// Unsent text per agent, kept while switching between chats (as Messages does).
    public var drafts: [String: String] = [:]

    /// The agents this phone uses, most recent conversation first; agents with no messages
    /// keep the host's order at the end (docs/agents-home.md).
    public var agentsByRecency: [ProfileData] {
        let newest = Dictionary(grouping: timeline.entries, by: \.profileId).mapValues { entries in
            // An unsent message counts as the newest of all.
            entries.map { $0.seq ?? Int.max }.max() ?? Int.min
        }
        return enabledProfiles.enumerated().sorted { a, b in
            let left = newest[a.element.profile_id] ?? Int.min
            let right = newest[b.element.profile_id] ?? Int.min
            return left != right ? left > right : a.offset < b.offset
        }.map(\.element)
    }

    /// When an agent's chat last changed, for ordering agents across computers (seq numbers
    /// are per computer). An unsent message counts as now; nil = no dated messages.
    public func newestActivity(for profileId: String) -> Date? {
        timeline.entries(for: profileId).compactMap { $0.seq == nil ? Date() : $0.date }.max()
    }

    /// The chat screen tells the client when it's on screen with the app in front.
    public func setChatVisible(_ visible: Bool) {
        chatVisible = visible
        if visible { markActiveChatRead() }
    }

    /// Marks the open chat read up to its newest message, here and on the host (which tells
    /// the user's other phones). Remembered offline and sent after reconnecting.
    private func markActiveChatRead() {
        guard chatVisible, let newest = timeline.newestSeq(for: activeProfileId),
              newest > readMarkers[activeProfileId] ?? 0 else { return }
        readMarkers[activeProfileId] = newest
        cacheChanged()
        sendRead(profileId: activeProfileId, seq: newest)
    }

    private func sendRead(profileId: String, seq: Int) {
        guard case .connected = state, hostTracksRead, let wsTask = webSocketTask,
              let instanceId = savedHost?.instanceId else { return }
        let envelope = Envelope(type: "chat.read", instance_id: instanceId, profile_id: profileId,
                                data: ChatReadData(seq: seq))
        Task { [weak self] in try? await self?.send(envelope, on: wsTask) }
    }

    /// The host's markers after `hello`: keep the furthest of the host's and this phone's,
    /// and send any reading done here while offline.
    private func mergeReadMarkers(_ host: [String: Int]?) {
        guard let host else {
            hostTracksRead = false
            return
        }
        hostTracksRead = true
        var merged = host
        for (profileId, local) in readMarkers where host[profileId] != nil {
            if local > host[profileId]! {
                merged[profileId] = local
                sendRead(profileId: profileId, seq: local)
            }
        }
        readMarkers = merged
    }

    /// Messages cached before the host sent times: fetch each such agent's newest page again
    /// so they get their times (docs/agents-home.md). Nothing cached is thrown away.
    private func fillInMissingTimes() {
        let agents = Set(timeline.entries.filter { $0.seq != nil && $0.date == nil }.map(\.profileId))
        guard !agents.isEmpty else { return }
        Task { [weak self] in
            for profileId in agents.sorted() {
                guard let self, case .connected = self.state else { return }
                guard let page = try? await self.request(
                    type: "history.fetch", profileId: profileId,
                    data: HistoryFetchData(before_seq: nil, limit: 100),
                    reply: HistoryPageData.self, timeout: 20) else { continue }
                self.timeline.applyPage(profileId: profileId, messages: page.messages, hasMore: page.has_more)
            }
        }
    }

    // MARK: - Chat settings (docs/chat-settings.md)

    /// Each agent chat's settings as last read from Hermes.
    @Published public private(set) var chatSettings: [String: ChatSettingsData] = [:]
    private var settingsRefresh: [String: Task<Void, Never>] = [:]

    /// Reads a chat's settings from Hermes. Keeps the last ones if the host can't answer.
    public func loadSettings(for profileId: String) async {
        guard let settings = try? await request(type: "settings.get", profileId: profileId, data: EmptyData(),
                                                reply: ChatSettingsData.self, timeout: 20) else { return }
        if chatSettings[profileId] != settings { chatSettings[profileId] = settings }
    }

    /// Changes a setting through Hermes' own command; shown straight away, then re-read.
    public func changeSetting(_ key: String, to value: SettingValue, in profileId: String) async throws {
        let before = chatSettings[profileId]
        applyLocally(key, value, in: profileId)
        do {
            _ = try await request(type: "settings.set", profileId: profileId, data: SettingChangeData(key: key, value: value),
                                  reply: SettingCommandResult.self, timeout: 20)
        } catch {
            chatSettings[profileId] = before  // refused or no answer: back to what Hermes had
            throw error
        }
        refreshSettingsSoon(profileId)
    }

    /// New chat, compress, undo, retry: Hermes' own commands.
    public func runChatAction(_ action: String, in profileId: String) async throws {
        _ = try await request(type: "settings.action", profileId: profileId, data: SettingActionData(action: action),
                              reply: SettingCommandResult.self, timeout: 20)
        refreshSettingsSoon(profileId)
    }

    private func applyLocally(_ key: String, _ value: SettingValue, in profileId: String) {
        guard var settings = chatSettings[profileId] else { return }
        switch (key, value) {
        case ("yolo", .flag(let on)): settings.yolo = on
        case ("show_reasoning", .flag(let on)): settings.show_reasoning = on
        case ("fast", .text(let mode)): settings.fast = mode
        case ("approvals", .text(let mode)): settings.approvals = mode
        case ("reasoning", .text(let effort)) where effort != "reset":
            settings.reasoning = .init(effort: effort, this_chat: true)
        case ("personality", .text(let name)): settings.personality?.current = name
        case ("title", .text(let title)): settings.title = title
        default: break
        }
        chatSettings[profileId] = settings
    }

    /// Hermes applies a command a moment after it arrives: read the settings again then.
    private func refreshSettingsSoon(_ profileId: String) {
        settingsRefresh[profileId]?.cancel()
        settingsRefresh[profileId] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await self?.loadSettings(for: profileId)
        }
    }

    // MARK: - Slash commands (docs/slash-commands.md)

    /// Each agent's commands, as its Hermes profile offers them (refreshed when its chat opens).
    @Published public private(set) var commands: [String: [SlashCommand]] = [:]

    /// Asks the host for an agent's commands. Keeps the last list if the host can't answer.
    public func loadCommands(for profileId: String) async {
        guard let result = try? await request(type: "commands.list", profileId: profileId, data: EmptyData(),
                                              reply: CommandsListResult.self, timeout: 15) else { return }
        if commands[profileId] != result.commands {
            commands[profileId] = result.commands
        }
    }

    // MARK: - Approval and question cards (docs/prompts.md)

    /// The newest card in an agent's chat that the agent is waiting on you to answer.
    public func openPrompt(for profileId: String, now: Date = Date()) -> PromptCard? {
        timeline.entries(for: profileId).last { $0.card?.isOpen(now: now) == true && $0.card?.needsAttention == true }?.card
    }

    /// Switches the model from a model-picker card. `needs_confirmation` comes back with
    /// Hermes' reason (e.g. an expensive model); call again with `confirmed` to go ahead.
    public func pickModel(_ card: PromptCard, in profileId: String, model: String, provider: String,
                          confirmed: Bool = false, scope: String? = nil) async throws -> (status: String, message: String?) {
        let ack = try await respondAck(profileId: profileId, PromptRespondData(
            card_id: card.id, model: model, provider: provider, confirmed: confirmed ? true : nil, scope: scope))
        return (ack.status, ack.message)
    }

    /// Prices and abilities of a provider's models: OpenRouter's whole tool-capable catalog,
    /// or the given models of another provider where Hermes knows them.
    public func modelCatalog(provider: String, models: [String] = [], in profileId: String) async throws -> CatalogResult {
        try await request(type: "models.catalog", profileId: profileId,
                          data: CatalogRequestData(provider: provider, models: models),
                          reply: CatalogResult.self, timeout: 30)
    }

    /// The companies hosting an OpenRouter model, and this agent's routing choice for it.
    public func modelHosts(_ model: String, in profileId: String) async throws -> HostsResult {
        try await request(type: "models.hosts", profileId: profileId, data: ModelRequestData(model: model),
                          reply: HostsResult.self, timeout: 30)
    }

    /// Saves which hosts OpenRouter may use for a model (Hermes' provider_routing, backed up first).
    public func setRouting(_ model: String, mode: String, hosts: [String] = [], noTraining: Bool = false,
                           in profileId: String) async throws -> RoutingChoice {
        try await request(type: "models.routing.set", profileId: profileId,
                          data: RoutingRequestData(model: model, mode: mode, hosts: hosts, no_training: noTraining),
                          reply: RoutingChoice.self, timeout: 30)
    }

    /// Opens Hermes' model picker in this chat (the same as typing /model).
    public func openModelPicker() async {
        await sendMessage("/model")
    }

    /// Answers an approval card: `once`, `session`, `always` or `deny` (with an optional reason).
    @discardableResult
    public func answerApproval(_ card: PromptCard, in profileId: String, choice: String,
                               reason: String? = nil) async throws -> String {
        try await respond(profileId: profileId, PromptRespondData(card_id: card.id, choice: choice, reason: reason))
    }

    /// Answers a question card with one or more of its options, or with typed text.
    @discardableResult
    public func answerQuestion(_ card: PromptCard, in profileId: String,
                               answers: [String]? = nil, text: String? = nil) async throws -> String {
        try await respond(profileId: profileId, PromptRespondData(card_id: card.id, answers: answers, text: text))
    }

    private func respond(profileId: String, _ data: PromptRespondData) async throws -> String {
        try await respondAck(profileId: profileId, data).status
    }

    private func respondAck(profileId: String, _ data: PromptRespondData) async throws -> PromptRespondAckData {
        // Switching models can take a while (Hermes checks the provider).
        let ack = try await request(type: "prompt.respond", profileId: profileId, data: data,
                                    reply: PromptRespondAckData.self, timeout: 60)
        if ack.status != "needs_confirmation" {
            timeline.setCardStatus(cardId: ack.card_id, status: ack.status)
        }
        return ack
    }

    // MARK: - Older messages (docs/chat-history.md)

    /// Whether scrolling to the top of an agent's chat can load more from the host.
    public func canLoadOlder(_ profileId: String) -> Bool {
        guard case .connected = state else { return false }
        return !timeline.completeProfiles.contains(profileId)
    }

    /// Fetches and shows the page of messages before the oldest one shown.
    public func loadOlderMessages(_ profileId: String) async {
        guard let page = await fetchOlderPage(profileId) else { return }
        applyOlderPage(page, for: profileId)
    }

    /// Fetches the page before the oldest message shown, without showing it yet (the chat
    /// screen waits until the reader's finger is off the screen). Nil if that failed.
    public func fetchOlderPage(_ profileId: String) async -> HistoryPageData? {
        guard canLoadOlder(profileId), !loadingOlder.contains(profileId) else { return nil }
        loadingOlder.insert(profileId)
        defer { loadingOlder.remove(profileId) }
        return try? await request(
            type: "history.fetch", profileId: profileId,
            data: HistoryFetchData(before_seq: timeline.oldestSeq(for: profileId), limit: 100),
            reply: HistoryPageData.self, timeout: 20)
    }

    public func applyOlderPage(_ page: HistoryPageData, for profileId: String) {
        timeline.applyPage(profileId: profileId, messages: page.messages, hasMore: page.has_more)
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
        // A new pairing replaces whatever this phone was connected to before, and starts
        // from the host's copy of the chats.
        closeSocket()
        if let old = savedHost {
            cacheStore?.delete(instanceId: old.instanceId)
            if old.instanceId != instanceId { SavedHost.clear(instanceId: old.instanceId, from: keychain) }
            savedHost = nil
        }
        cacheStore?.delete(instanceId: instanceId)
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
            onPaired?(self)

            await completeSessionHandshake(wsTask: wsTask, host: host)
        } catch {
            closeSocket()
            state = .error(error.localizedDescription)
        }
    }

    /// When the last reconnect attempt failed, and how long to wait before the next one.
    private var lastFailedAttempt: Date?
    var minimumRetryInterval: TimeInterval = 2

    /// Reconnects to the saved host, if there is one. Safe to call repeatedly: does
    /// nothing while a connection attempt is running or already connected.
    public func resumeSavedSession() async {
        guard let host = savedHost else { return }
        guard !isBusy, !isForgetting else { return }
        // A safety net: never hammer a computer that just refused, whatever asks to retry.
        if let failed = lastFailedAttempt, Date().timeIntervalSince(failed) < minimumRetryInterval { return }

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
            lastFailedAttempt = Date()
            state = .error(RouteProberError.certificateMismatch.localizedDescription)
        } catch {
            closeSocket()
            lastFailedAttempt = Date()
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
                    since_rev: currentRev,
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
            applyInstanceName(ack.instance_name)
            reconcileProfileChoice()
            // Live bubbles from before the reconnect are previews; the replay is the truth.
            timeline.dropUnfinishedReplies()
            // Agents deleted while this phone was away.
            let current = Set(ack.profiles.map(\.profile_id))
            for gone in Set(timeline.entries.map(\.profileId)).subtracting(current) {
                timeline.removeEntries(for: gone)
            }
            if ack.replay == "recent" {
                timeline.replaceSavedWithRecent()  // each agent's newest messages follow
            }
            if let rev = ack.rev { currentRev = max(currentRev, rev) }
            mergeReadMarkers(ack.read)
            if ack.message_times == true { fillInMissingTimes() }
            agentActivity = [:]
            let activeName = activeProfile?.name ?? ack.profiles.first?.name ?? "Hermes Agent"
            state = .connected(instanceName: ack.instance_name, profileName: activeName)

            startHeartbeat()
            startReceiveLoop(wsTask: wsTask)
            markActiveChatRead()
            cacheChanged()  // the agent list and change number may be new
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
        if let host = savedHost {
            cacheStore?.delete(instanceId: host.instanceId)
            SavedHost.clear(instanceId: host.instanceId, from: keychain)
        }
        savedHost = nil
        resetSessionData()
        state = .disconnected
    }

    private func setActivity(_ profileId: String, active: Bool, status: String?) {
        guard active else {
            agentActivity[profileId] = nil
            return
        }
        // Keep when it started working, so the phone can show "· 12 min".
        let since = agentActivity[profileId]?.since ?? Date()
        let activity = AgentActivity(status: status, since: since, token: UUID())
        agentActivity[profileId] = activity
        let timeout = activityTimeout
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            // Only clear if no newer ping arrived in the meantime.
            if self?.agentActivity[profileId]?.token == activity.token {
                self?.agentActivity[profileId] = nil
            }
        }
    }

    private func resetSessionData() {
        cacheSaveTask?.cancel()
        cacheSaveTask = nil
        agentActivity = [:]
        timeline = ChatTimeline()
        profiles = []
        currentSeq = 0
        currentRev = 0
        readMarkers = [:]
        hostTracksRead = false
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
        markActiveChatRead()
    }

    /// New agent list from the host (another phone created or deleted one).
    private func applyProfiles(_ newProfiles: [ProfileData]) {
        let removed = Set(profiles.map(\.profile_id)).subtracting(newProfiles.map(\.profile_id))
        profiles = newProfiles
        for id in removed {
            timeline.removeEntries(for: id)
            readMarkers[id] = nil
        }
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

    private func request<T: Codable, R: Codable>(type: String, profileId: String? = nil, data: T,
                                                 reply: R.Type, timeout: Double) async throws -> R {
        guard case .connected = state, let wsTask = webSocketTask, let instanceId = savedHost?.instanceId else {
            throw HostError(code: "DISCONNECTED", reason: "Not connected to the host.")
        }
        let envelope = Envelope(type: type, instance_id: instanceId, profile_id: profileId, data: data)
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
    public nonisolated static func makeChatSendEnvelope(text: String, instanceId: String, profileId: String,
                                                        files: [String]? = nil,
                                                        voice: VoiceDetails? = nil) -> Envelope<ChatSendData> {
        Envelope(
            type: "chat.send",
            instance_id: instanceId,
            profile_id: profileId,
            data: ChatSendData(text: text, files: files, voice: voice)
        )
    }

    /// Sends `text` to the active profile. The message appears in the timeline straight
    /// away; a failed send is marked on that bubble instead of dropping the connection.
    public func sendMessage(_ text: String, files: [ChatFile] = [], voice: VoiceDetails? = nil) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !files.isEmpty,
              case .connected = state,
              let wsTask = webSocketTask,
              let instanceId = savedHost?.instanceId else {
            return
        }

        let envelope = Self.makeChatSendEnvelope(text: trimmed, instanceId: instanceId, profileId: activeProfileId,
                                                 files: files.isEmpty ? nil : files.map(\.file_id), voice: voice)
        timeline.addOutgoing(id: envelope.id, profileId: activeProfileId, text: trimmed,
                             files: files.isEmpty ? nil : files, voice: voice)

        do {
            try await send(envelope, on: wsTask)
            timeline.markSent(id: envelope.id)
        } catch {
            timeline.markFailed(id: envelope.id, reason: error.localizedDescription)
        }
    }

    // MARK: - Files (docs/files.md)

    /// Owner's decision: up to 100 MB per file, 10 per message.
    public nonisolated static let maxFileBytes = 100 * 1024 * 1024
    public nonisolated static let maxFilesPerMessage = 10

    /// Where downloaded and sent files are kept on the phone (iOS may clear it; they're
    /// fetched again from the instance).
    public var fileCacheRoot: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Lekora/files", isDirectory: true)
    private var downloads: [String: Task<URL, Error>] = [:]

    /// Where this file is (or will be) kept on the phone.
    public func localFileURL(_ file: ChatFile) -> URL {
        let instance = (savedHost?.instanceId ?? "unpaired").replacingOccurrences(of: "/", with: "_")
        let name = file.name.replacingOccurrences(of: "/", with: "_")
        return fileCacheRoot.appendingPathComponent(instance, isDirectory: true)
            .appendingPathComponent(file.file_id, isDirectory: true)
            .appendingPathComponent(name.isEmpty ? "file" : name)
    }

    /// The file on the phone, if it's here already.
    public func cachedFileURL(_ file: ChatFile) -> URL? {
        let url = localFileURL(file)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The file on the phone, fetched from the instance in pieces if needed.
    public func fileURL(for file: ChatFile) async throws -> URL {
        if let cached = cachedFileURL(file) { return cached }
        if let running = downloads[file.file_id] { return try await running.value }
        let task = Task { @MainActor [weak self] () throws -> URL in
            guard let self else { throw CancellationError() }
            return try await self.download(file)
        }
        downloads[file.file_id] = task
        defer { downloads[file.file_id] = nil }
        return try await task.value
    }

    private func download(_ file: ChatFile) async throws -> URL {
        let target = localFileURL(file)
        let folder = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let partial = folder.appendingPathComponent(".download")
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }
        var offset = 0
        while true {
            let piece = try await request(type: "file.read", data: FileReadData(file_id: file.file_id, offset: offset),
                                          reply: FileReadResult.self, timeout: 30)
            guard let bytes = Data(base64Encoded: piece.data) else {
                throw HostError(code: "INVALID_FILE", reason: "The file arrived damaged.")
            }
            try handle.write(contentsOf: bytes)
            offset += bytes.count
            if piece.done || bytes.isEmpty { break }
        }
        try handle.close()
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: partial, to: target)
        return target
    }

    /// Sends a file on the phone to the instance in pieces; it's then ready to go with a
    /// message. A copy is kept so it shows straight away in the chat.
    public func uploadFile(at source: URL, name: String, mime: String, to profileId: String,
                           progress: @escaping (Double) -> Void = { _ in }) async throws -> ChatFile {
        let size = (try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size <= Self.maxFileBytes else {
            throw HostError(code: "FILE_TOO_LARGE", reason: "Files can be up to 100 MB.")
        }
        let begun = try await request(type: "file.upload.begin", profileId: profileId,
                                      data: FileUploadBeginData(name: name, mime: mime, size: size),
                                      reply: FileUploadBeginResult.self, timeout: 20)
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        var offset = 0
        progress(0)
        while offset < size {
            let bytes = try handle.read(upToCount: max(begun.chunk_size, 1)) ?? Data()
            guard !bytes.isEmpty else { break }
            let answer = try await request(type: "file.upload.chunk", profileId: profileId,
                                           data: FileUploadChunkData(file_id: begun.file_id, offset: offset,
                                                                     data: bytes.base64EncodedString()),
                                           reply: FileUploadChunkResult.self, timeout: 30)
            offset = answer.received
            progress(size == 0 ? 1 : Double(offset) / Double(size))
        }
        let done = try await request(type: "file.upload.end", profileId: profileId, data: FileIdData(file_id: begun.file_id),
                                     reply: FileUploadEndResult.self, timeout: 20)
        progress(1)
        let kept = localFileURL(done.file)
        try? FileManager.default.createDirectory(at: kept.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.copyItem(at: source, to: kept)
        return done.file
    }

    /// Sends a recording as a voice note: uploaded, then sent with its length and waveform;
    /// Hermes transcribes it (docs/voice.md). Throws if the upload fails.
    public func sendVoiceNote(at recording: URL, duration: Double, waveform: [Double]) async throws {
        let profileId = activeProfileId
        let file = try await uploadFile(at: recording, name: recording.lastPathComponent, mime: "audio/mp4", to: profileId)
        guard profileId == activeProfileId else { return }
        await sendMessage("", files: [file], voice: VoiceDetails(duration: duration, waveform: waveform))
    }

    // MARK: - Hearing replies (docs/voice.md §2)

    /// Each agent's voice settings, as last read from the instance.
    @Published public private(set) var voiceSettings: [String: AgentVoiceSettings] = [:]
    /// Each agent's Hermes voice, if it has a cloud one.
    @Published public private(set) var hermesVoice: [String: HermesVoiceInfo] = [:]

    public func loadVoiceSettings(for profileId: String) async {
        guard let got = try? await request(type: "voice.settings.get", profileId: profileId, data: EmptyData(),
                                           reply: VoiceSettingsGetResult.self, timeout: 20) else { return }
        voiceSettings[profileId] = got.settings
        hermesVoice[profileId] = got.hermes_voice
    }

    /// Saves an agent's voice settings on the instance (shown here straight away).
    public func setVoiceSettings(_ settings: AgentVoiceSettings, for profileId: String) async throws {
        let before = voiceSettings[profileId]
        voiceSettings[profileId] = settings
        do {
            let saved = try await request(type: "voice.settings.set", profileId: profileId,
                                          data: VoiceSettingsData(settings: settings),
                                          reply: VoiceSettingsData.self, timeout: 15)
            voiceSettings[profileId] = saved.settings
        } catch {
            voiceSettings[profileId] = before
            throw error
        }
    }

    /// A reply in the agent's Hermes voice: an audio file on the phone.
    public func hermesSpeech(for seq: Int, in profileId: String) async throws -> URL {
        let got = try await request(type: "voice.speak", profileId: profileId, data: VoiceSpeakData(seq: seq),
                                    reply: VoiceSpeakResult.self, timeout: 120)
        return try await fileURL(for: got.file)
    }

    /// The space files take on this instance.
    public func filesUsage() async -> FilesUsage? {
        try? await request(type: "files.usage", data: EmptyData(), reply: FilesUsage.self, timeout: 15)
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

        // Each computer has its own connection: anything addressed to another one is ignored.
        if let from = header.instance_id, let host = savedHost, from != host.instanceId { return }

        switch header.type {
        case "voice.settings.changed":
            // Changed on another phone.
            guard let envelope = try? decoder.decode(Envelope<VoiceSettingsData>.self, from: data),
                  let profileId = envelope.profile_id else { return }
            voiceSettings[profileId] = envelope.data.settings
        case "instance.changed":
            // Renamed from another phone.
            guard let envelope = try? decoder.decode(Envelope<InstanceNameData>.self, from: data) else { return }
            applyInstanceName(envelope.data.instance_name)
        case "profiles.changed":
            guard let envelope = try? decoder.decode(Envelope<ProfilesChangedData>.self, from: data) else { return }
            applyProfiles(envelope.data.profiles)
        case "chat.message":
            guard let envelope = try? decoder.decode(Envelope<ChatMessageData>.self, from: data) else { return }
            currentSeq = max(currentSeq, envelope.data.seq)
            if let rev = envelope.data.rev { currentRev = max(currentRev, rev) }
            let profileId = envelope.profile_id ?? activeProfileId
            timeline.applyIncoming(
                seq: envelope.data.seq,
                profileId: profileId,
                role: envelope.data.role,
                text: envelope.data.text,
                draftId: envelope.data.draft_id,
                clientId: envelope.data.client_id,
                date: envelope.data.date,
                card: envelope.data.card,
                files: envelope.data.files,
                voice: envelope.data.voice,
                transcript: envelope.data.transcript
            )
            if profileId == activeProfileId { markActiveChatRead() }
            if envelope.data.role == "system", chatSettings[profileId] != nil {
                refreshSettingsSoon(profileId)  // e.g. a typed /yolo or /reasoning, answered by Hermes
            }
        case "chat.read":
            // Read on another phone.
            guard let envelope = try? decoder.decode(Envelope<ChatReadData>.self, from: data),
                  let profileId = envelope.profile_id else { return }
            if envelope.data.seq > readMarkers[profileId] ?? 0 {
                readMarkers[profileId] = envelope.data.seq
                cacheChanged()
            }
        case "chat.draft":
            guard let envelope = try? decoder.decode(Envelope<ChatDraftData>.self, from: data) else { return }
            timeline.applyDraft(draftId: envelope.data.draft_id,
                                profileId: envelope.profile_id ?? activeProfileId,
                                text: envelope.data.text)
        case "chat.typing":
            guard let envelope = try? decoder.decode(Envelope<ChatTypingData>.self, from: data) else { return }
            setActivity(envelope.profile_id ?? activeProfileId,
                        active: envelope.data.active, status: envelope.data.status)
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
        agentActivity = [:]
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

    /// Stops this client for good without forgetting anything (its computer was paired
    /// again on a new client).
    public func shutDown() {
        cacheSaveTask?.cancel()
        cacheSaveTask = nil
        closeSocket()
        state = .disconnected
    }

    // MARK: - The computer's name (docs/multiple-instances.md)

    /// Renames the computer on the host, so every phone sees the new name.
    public func renameInstance(_ name: String) async throws {
        let result = try await request(type: "instance.rename", profileId: nil, data: InstanceRenameData(name: name),
                                       reply: InstanceNameData.self, timeout: 10)
        applyInstanceName(result.instance_name)
    }

    private func applyInstanceName(_ name: String) {
        guard var host = savedHost, !name.isEmpty, host.instanceName != name else { return }
        host.instanceName = name
        try? host.saveName(to: keychain)
        savedHost = host
        if case .connected(_, let profileName) = state { state = .connected(instanceName: name, profileName: profileName) }
    }

    /// Drops the connection but keeps the saved host, so the app can reconnect later.
    public func disconnect() {
        closeSocket()
        state = .disconnected
    }
}

/// An agent at work, as shown by the "thinking…" indicator.
public struct AgentActivity: Equatable {
    /// What it's doing, when Hermes says ("Searching the web…").
    public let status: String?
    /// When it started working (kept across pings).
    public let since: Date
    let token: UUID
}
