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
            if let saved {
                loadCache(for: saved)
                restoreQueuedSends()
            }
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
        groups = cache.groups ?? []
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
            read: readMarkers, hostTracksRead: hostTracksRead, profiles: profiles, groups: groups))
    }

    /// True when a host is paired and some of its chats are known (shown while reconnecting).
    public var hasCachedChats: Bool {
        savedHost != nil && !profiles.isEmpty && !(savedHost?.enabledProfileIds ?? []).isEmpty
    }

    // MARK: - Offline (docs/auto-reconnect.md, "Offline")

    /// Set when reconnecting can't fix it: the instance's certificate changed, or it refused this
    /// phone. Anything else (the gateway restarting, no network) is just being offline for now.
    @Published public private(set) var pairingProblem = false

    /// The chats stay usable without a connection: read everything kept on the phone, write
    /// messages that go out once it's back (owner, 2026-11-15: a gateway restart threw him out).
    public var canWorkOffline: Bool { hasCachedChats && !pairingProblem }

    /// Messages written while offline, sent in order once connected again. Kept on the phone, so
    /// quitting the app before they go doesn't lose them.
    private var queuedSends: [Envelope<ChatSendData>] = [] {
        didSet { saveQueuedSends() }
    }

    private var queueKey: String? { savedHost.map { "lekora.queued.\($0.instanceId)" } }

    private func saveQueuedSends() {
        guard let queueKey else { return }
        if queuedSends.isEmpty {
            UserDefaults.standard.removeObject(forKey: queueKey)
        } else if let data = try? JSONEncoder().encode(queuedSends) {
            UserDefaults.standard.set(data, forKey: queueKey)
        }
    }

    /// After a relaunch: the waiting messages, back in their chats.
    private func restoreQueuedSends() {
        guard let queueKey, let data = UserDefaults.standard.data(forKey: queueKey),
              let saved = try? JSONDecoder().decode([Envelope<ChatSendData>].self, from: data) else { return }
        for envelope in saved where !timeline.entries.contains(where: { $0.id == envelope.id }) {
            timeline.addOutgoing(id: envelope.id, profileId: envelope.profile_id ?? activeProfileId, text: envelope.data.text)
        }
        queuedSends = saved
    }

    /// How many messages are waiting for the connection.
    public var queuedCount: Int { queuedSends.count }

    private func flushQueuedSends(on wsTask: URLSessionWebSocketTask) {
        guard !queuedSends.isEmpty else { return }
        let waiting = queuedSends
        queuedSends = []
        Task { [weak self] in
            for envelope in waiting {
                guard let self else { return }
                do {
                    try await self.send(envelope, on: wsTask)
                    self.timeline.markSent(id: envelope.id)
                } catch {
                    self.queuedSends.append(envelope)  // dropped again: next time
                }
            }
        }
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

    // MARK: - Group chats (docs/group-chats.md)

    /// This instance's group chats.
    @Published public private(set) var groups: [GroupData] = []

    public func group(for key: String) -> GroupData? {
        groups.first { $0.key == key }
    }

    /// Groups whose members include at least two agents this phone knows.
    public var openableGroups: [GroupData] { groups }

    public func loadGroups() async {
        guard let result = try? await request(type: "groups.list", data: EmptyData(),
                                              reply: GroupsListData.self, timeout: 15) else { return }
        applyGroups(result.groups)
    }

    private func applyGroups(_ list: [GroupData]) {
        if groups != list { groups = list }
        // Deleted groups: their chats go.
        let keys = Set(list.map(\.key))
        for gone in Set(timeline.entries.map(\.profileId)) where GroupData.isKey(gone) && !keys.contains(gone) {
            timeline.removeEntries(for: gone)
        }
        cacheChanged()
    }

    @discardableResult
    public func createGroup(name: String, members: [String]) async throws -> GroupData {
        let made = try await request(type: "group.create", data: GroupCreateRequest(name: name, members: members),
                                     reply: GroupResult.self, timeout: 15).group
        applyGroups(groups.filter { $0.group_id != made.group_id } + [made])
        return made
    }

    @discardableResult
    public func updateGroup(_ groupId: String, name: String? = nil, members: [String]? = nil) async throws -> GroupData {
        let changed = try await request(type: "group.update",
                                        data: GroupUpdateRequest(group_id: groupId, name: name, members: members),
                                        reply: GroupResult.self, timeout: 15).group
        applyGroups(groups.map { $0.group_id == changed.group_id ? changed : $0 })
        return changed
    }

    /// @mentioning agents in a one-to-one chat (owner, 2026-11-20): the group of that agent and them
    /// (reused when one has exactly them), which starts with the chat's last few messages.
    @discardableResult
    public func startGroup(from profileId: String, with members: [String]) async throws -> GroupData {
        let started = try await request(type: "group.start", data: GroupStartRequest(from: profileId, members: members),
                                        reply: GroupStartResult.self, timeout: 20).group
        applyGroups(groups.filter { $0.group_id != started.group_id } + [started])
        return started
    }

    /// Each member's side of a group, from Hermes (model, title, context, tokens, cost).
    public func groupDetails(_ groupId: String) async throws -> GroupDetails {
        try await request(type: "group.details", data: GroupIdRequest(group_id: groupId),
                          reply: GroupDetails.self, timeout: 20)
    }

    public func deleteGroup(_ groupId: String) async throws {
        _ = try await request(type: "group.delete", data: GroupDeleteRequest(group_id: groupId),
                              reply: GroupIdResult.self, timeout: 15)
        applyGroups(groups.filter { $0.group_id != groupId })
    }

    // MARK: - Skills (docs/skills.md)

    public func skills(for profileId: String) async throws -> [SkillInfo] {
        try await request(type: "skills.list", profileId: profileId, data: EmptyData(), reply: SkillsListData.self, timeout: 30).skills
    }

    /// Every skill across every agent, with the agents that have it.
    public func allSkills() async throws -> [SharedSkill] {
        try await request(type: "skills.all", data: EmptyData(), reply: SharedSkillsData.self, timeout: 60).skills
    }

    /// Gives `agents` a skill that `profileId` has.
    @discardableResult
    public func copySkill(_ name: String, from profileId: String, to agents: [String]) async throws -> SkillCopyResult {
        try await request(type: "skill.copy", profileId: profileId, data: SkillCopyRequest(name: name, to: agents),
                          reply: SkillCopyResult.self, timeout: 240)
    }

    // MARK: - MCP servers (docs/mcp.md)

    public func mcpServers() async throws -> [McpServer] {
        try await request(type: "mcp.all", data: EmptyData(), reply: McpServersData.self, timeout: 60).servers
    }

    public func mcpCatalog(_ query: String = "") async throws -> [McpCatalogEntry] {
        try await request(type: "mcp.catalog", data: McpQuery(query: query), reply: McpCatalogData.self, timeout: 30).entries
    }

    public func searchMcpRegistry(_ query: String) async throws -> [McpRegistryResult] {
        try await request(type: "mcp.registry.search", data: McpQuery(query: query), reply: McpRegistryData.self, timeout: 40).results
    }

    /// Adds a server for the chosen agents; the result says whether it answers or needs a sign-in.
    public func addMcpServer(_ add: McpAddRequest) async throws -> McpChangeResult {
        try await request(type: "mcp.add", data: add, reply: McpChangeResult.self, timeout: 240)
    }

    /// Gives `agents` a server `profileId` has (its keys and sign-in are copied on the Hermes instance).
    public func copyMcpServer(_ name: String, from profileId: String, to agents: [String]) async throws -> McpChangeResult {
        try await request(type: "mcp.copy", profileId: profileId, data: McpCopyRequest(name: name, to: agents),
                          reply: McpChangeResult.self, timeout: 120)
    }

    public func setMcpServer(_ name: String, enabled: Bool, for profileId: String) async throws {
        _ = try await request(type: "mcp.enable", profileId: profileId, data: McpEnableRequest(name: name, enabled: enabled),
                              reply: McpEnableResult.self, timeout: 60)
    }

    public func removeMcpServer(_ name: String, for profileId: String) async throws {
        _ = try await request(type: "mcp.remove", profileId: profileId, data: McpNameRequest(name: name),
                              reply: McpNameRequest.self, timeout: 60)
    }

    public func testMcpServer(_ name: String, for profileId: String) async throws -> McpTestResult {
        try await request(type: "mcp.test", profileId: profileId, data: McpNameRequest(name: name),
                          reply: McpTestResult.self, timeout: 120)
    }

    public func startMcpSignIn(_ name: String, for profileId: String, redirect: String,
                               shareWith: [String] = []) async throws -> McpSignIn {
        try await request(type: "mcp.signin.start", profileId: profileId,
                          data: McpSignInStart(name: name, redirect_uri: redirect, share_with: shareWith.isEmpty ? nil : shareWith),
                          reply: McpSignIn.self, timeout: 60)
    }

    public func finishMcpSignIn(_ flowId: String, callback: URL) async throws -> McpSignIn {
        try await request(type: "mcp.signin.finish", data: McpSignInFinish(flow_id: flowId, callback_url: callback.absoluteString),
                          reply: McpSignIn.self, timeout: 120)
    }

    public func cancelMcpSignIn(_ flowId: String) async {
        _ = try? await request(type: "mcp.signin.cancel", data: McpFlowRequest(flow_id: flowId), reply: McpCancelResult.self, timeout: 20)
    }

    public func skill(_ name: String, for profileId: String) async throws -> SkillDetail {
        try await request(type: "skill.get", profileId: profileId, data: SkillNameRequest(name: name), reply: SkillDetail.self, timeout: 20)
    }

    @discardableResult
    public func setSkill(_ name: String, enabled: Bool, for profileId: String) async throws -> SkillInfo {
        try await request(type: "skill.enable", profileId: profileId, data: SkillEnableRequest(name: name, enabled: enabled),
                          reply: SkillResult.self, timeout: 20).skill
    }

    public func searchSkills(_ query: String) async throws -> [CatalogSkill] {
        try await request(type: "skills.search", data: SkillSearchRequest(query: query), reply: SkillSearchResult.self, timeout: 60).results
    }

    public func scanSkill(_ identifier: String) async throws -> SkillScan {
        try await request(type: "skill.scan", data: SkillIdentifierRequest(identifier: identifier), reply: SkillScan.self, timeout: 120)
    }

    @discardableResult
    public func installSkill(_ identifier: String, for profileId: String) async throws -> SkillInfo {
        try await request(type: "skill.install", profileId: profileId, data: SkillIdentifierRequest(identifier: identifier),
                          reply: SkillResult.self, timeout: 180).skill
    }

    public func removeSkill(_ name: String, for profileId: String) async throws {
        _ = try await request(type: "skill.remove", profileId: profileId, data: SkillNameRequest(name: name),
                              reply: SkillRemoveResult.self, timeout: 120)
    }

    public func draftSkill(_ description: String) async throws -> SkillDraft {
        try await request(type: "skill.draft", data: SkillDraftRequest(description: description), reply: SkillDraft.self, timeout: 120)
    }

    @discardableResult
    public func saveSkill(content: String, name: String?, category: String?, create: Bool, for profileId: String) async throws -> SkillInfo {
        try await request(type: "skill.save", profileId: profileId,
                          data: SkillSaveRequest(name: name, content: content, category: category, create: create),
                          reply: SkillResult.self, timeout: 30).skill
    }

    // MARK: - Analytics (docs/analytics.md)

    /// Usage and spend for the last `days` (1, 7 or 30), for every agent or one.
    public func analytics(days: Int, profileId: String? = nil) async throws -> AnalyticsReport {
        try await request(type: "analytics.get", data: AnalyticsRequest(days: days, profile_id: profileId),
                          reply: AnalyticsReport.self, timeout: 45)
    }

    // MARK: - Delegation (docs/delegation.md)

    /// Stops one piece of delegated work on a Delegated card, or (nil) everything still running on it.
    @discardableResult
    public func stopHelpers(profileId: String, seq: Int, helperId: String?) async throws -> [String] {
        try await request(type: "delegation.stop", profileId: profileId,
                          data: DelegationStopRequest(seq: seq, helper_id: helperId),
                          reply: DelegationStopData.self, timeout: 15).stopped
    }

    /// An agent's name from its profile id (the id itself when it isn't known here).
    public func agentName(_ profileId: String) -> String {
        profiles.first { $0.profile_id == profileId }?.name ?? profileId
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
    /// When this connection was first lost (cleared once connected).
    private var offlineSince: Date?

    /// Time to try again: every 5 s for the first two minutes offline (a gateway restart takes
    /// seconds), then every 30 s.
    public var retryDue: Bool {
        guard let failed = lastFailedAttempt else { return true }
        let offlineFor = Date().timeIntervalSince(offlineSince ?? failed)
        return Date().timeIntervalSince(failed) >= (offlineFor < 120 ? 5 : 30)
    }
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
            if offlineSince == nil { offlineSince = Date() }
            pairingProblem = true
            state = .error(RouteProberError.certificateMismatch.localizedDescription)
        } catch {
            closeSocket()
            lastFailedAttempt = Date()
            if offlineSince == nil { offlineSince = Date() }
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
                pairingProblem = true
                state = .error("Handshake rejected by host.")
                return
            }

            self.profiles = ack.profiles
            applyInstanceName(ack.instance_name)
            userName = ack.user_name
            reconcileProfileChoice()
            // Live bubbles from before the reconnect are previews; the replay is the truth.
            timeline.dropUnfinishedReplies()
            // Agents deleted while this phone was away.
            let current = Set(ack.profiles.map(\.profile_id))
            for gone in Set(timeline.entries.map(\.profileId)).subtracting(current) where !GroupData.isKey(gone) {
                timeline.removeEntries(for: gone)  // a group's chat is checked when the groups arrive
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
            pairingProblem = false
            offlineSince = nil

            startHeartbeat()
            startReceiveLoop(wsTask: wsTask)
            flushQueuedSends(on: wsTask)  // what was written while offline
            markActiveChatRead()
            cacheChanged()  // the agent list and change number may be new
            Task { await self.loadGroups() }
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

    /// Shows another chosen agent's conversation (or a group's); new messages go to it.
    public func switchToProfile(_ id: String) {
        if GroupData.isKey(id) {
            // A group isn't remembered as the chat to reopen: the agents list is.
            guard groups.contains(where: { $0.key == id }) else { return }
            activeProfileId = id
            markActiveChatRead()
            return
        }
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
                                                        voice: VoiceDetails? = nil,
                                                        handsFree: Bool = false,
                                                        about: String? = nil,
                                                        review: [ReviewComment]? = nil) -> Envelope<ChatSendData> {
        Envelope(
            type: "chat.send",
            instance_id: instanceId,
            profile_id: profileId,
            data: ChatSendData(text: text, files: files, voice: voice, hands_free: handsFree ? true : nil,
                               about: about.map { ArtifactRef(artifact_id: $0) }, review: review)
        )
    }

    /// Sends `text` to the active profile. The message appears in the timeline straight
    /// away; a failed send is marked on that bubble instead of dropping the connection.
    public func sendMessage(_ text: String, files: [ChatFile] = [], voice: VoiceDetails? = nil,
                            handsFree: Bool = false, about: ArtifactCard? = nil,
                            review: [ReviewComment]? = nil) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !files.isEmpty || review?.isEmpty == false,
              let instanceId = savedHost?.instanceId else {
            return
        }
        guard case .connected = state, let wsTask = webSocketTask else {
            // Offline: kept on the phone and sent once connected (voice notes and files need the
            // connection to upload, so they aren't queued).
            guard files.isEmpty, voice == nil, !handsFree else { return }
            let envelope = Self.makeChatSendEnvelope(text: trimmed, instanceId: instanceId, profileId: activeProfileId,
                                                     about: about?.artifact_id, review: review)
            timeline.addOutgoing(id: envelope.id, profileId: activeProfileId, text: trimmed, about: about, review: review)
            queuedSends.append(envelope)
            return
        }

        let envelope = Self.makeChatSendEnvelope(text: trimmed, instanceId: instanceId, profileId: activeProfileId,
                                                 files: files.isEmpty ? nil : files.map(\.file_id), voice: voice,
                                                 handsFree: handsFree, about: about?.artifact_id, review: review)
        timeline.addOutgoing(id: envelope.id, profileId: activeProfileId, text: trimmed,
                             files: files.isEmpty ? nil : files, voice: voice, about: about, review: review)

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
    /// Kept, not a cache iOS may clear (owner, 2026-11-15: voice notes shouldn't need fetching again).
    public var fileCacheRoot: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
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

    /// Files kept on the phone stay out of iCloud backups (they're on the Hermes instance anyway).
    private func keepOutOfBackups() {
        try? FileManager.default.createDirectory(at: fileCacheRoot, withIntermediateDirectories: true)
        var root = fileCacheRoot
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
    }

    private func download(_ file: ChatFile) async throws -> URL {
        keepOutOfBackups()
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
    public func sendVoiceNote(at recording: URL, duration: Double, waveform: [Double],
                              handsFree: Bool = false) async throws {
        let profileId = activeProfileId
        let file = try await uploadFile(at: recording, name: recording.lastPathComponent, mime: "audio/mp4", to: profileId)
        guard profileId == activeProfileId else { return }
        await sendMessage("", files: [file], voice: VoiceDetails(duration: duration, waveform: waveform),
                          handsFree: handsFree)
    }

    // MARK: - Hearing replies (docs/voice.md §2)

    /// Each agent's voice settings, as last read from the instance.
    @Published public private(set) var voiceSettings: [String: AgentVoiceSettings] = [:]
    /// Each agent's Hermes voice, if it has a cloud one.
    @Published public private(set) var hermesVoice: [String: HermesVoiceInfo] = [:]

    /// The default personality-voice instructions, from the instance.
    @Published public private(set) var defaultStyleInstructions: String?

    public func loadVoiceSettings(for profileId: String) async {
        guard let got = try? await request(type: "voice.settings.get", profileId: profileId, data: EmptyData(),
                                           reply: VoiceSettingsGetResult.self, timeout: 20) else { return }
        voiceSettings[profileId] = got.settings
        hermesVoice[profileId] = got.hermes_voice
        if let text = got.default_style_instructions { defaultStyleInstructions = text }
    }

    // MARK: - Past chats (docs/chats.md)

    /// Each agent's current Hermes conversation (the chat shows only it; earlier ones fold away).
    @Published public private(set) var currentChat: [String: String] = [:]
    @Published public private(set) var pastChats: [String: [ChatSessionInfo]] = [:]

    public func loadChats(for profileId: String) async {
        guard let got = try? await request(type: "chats.list", profileId: profileId, data: ChatsQuery(query: nil),
                                           reply: ChatSessionsData.self, timeout: 20) else { return }
        pastChats[profileId] = got.chats
        if let current = got.current {
            currentChat[profileId] = current
            await loadConversation(current, in: profileId)
        }
    }

    /// The current conversation's messages, each with its conversation: messages kept on the phone
    /// from before learn which one they're in (so nothing from another conversation shows).
    private func loadConversation(_ sessionId: String, in profileId: String) async {
        guard let messages = try? await chatHistory(sessionId, in: profileId) else { return }
        timeline.applyPage(profileId: profileId, messages: messages, hasMore: true)
        cacheChanged()
    }

    /// Past chats whose title or messages contain `query` (with the matching words).
    public func searchChats(_ query: String, in profileId: String) async throws -> [ChatSessionInfo] {
        try await request(type: "chats.list", profileId: profileId, data: ChatsQuery(query: query),
                          reply: ChatSessionsData.self, timeout: 30).chats
    }

    public func chatHistory(_ sessionId: String, in profileId: String) async throws -> [ChatMessageData] {
        try await request(type: "chat.history", profileId: profileId, data: ChatSessionRef(session_id: sessionId),
                          reply: ChatHistoryResult.self, timeout: 30).messages
    }

    /// Continue an earlier conversation (Hermes' own /resume).
    public func resumeChat(_ sessionId: String, in profileId: String) async throws {
        _ = try await request(type: "chat.resume", profileId: profileId, data: ChatSessionRef(session_id: sessionId),
                              reply: ChatSessionRef.self, timeout: 30)
        currentChat[profileId] = sessionId
        // Its messages may not be on the phone yet: fetch them into the chat.
        await loadConversation(sessionId, in: profileId)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await loadChats(for: profileId)
        await loadSettings(for: profileId)  // the chat's title is the resumed one's
    }

    // MARK: - Artifacts (docs/artifacts.md)

    /// The newest version of each artifact the instance told this phone about (open viewers reload).
    @Published public private(set) var artifactVersions: [String: Int] = [:]

    public func artifacts(for profileId: String) async throws -> [ArtifactCard] {
        try await request(type: "artifacts.list", profileId: profileId, data: EmptyData(),
                          reply: ArtifactsListResult.self, timeout: 20).artifacts
    }

    public func artifact(_ id: String, version: Int? = nil, in profileId: String) async throws -> ArtifactDetail {
        try await request(type: "artifact.get", profileId: profileId, data: ArtifactGetData(artifact_id: id, version: version),
                          reply: ArtifactDetail.self, timeout: 30)
    }

    /// Your edit, as a new version. Throws `ARTIFACT_CHANGED` when a newer version exists.
    public func saveArtifact(_ id: String, content: String, baseVersion: Int, note: String? = nil,
                             in profileId: String) async throws -> ArtifactCard {
        let saved = try await request(type: "artifact.save", profileId: profileId,
                                      data: ArtifactSaveData(artifact_id: id, content: content, base_version: baseVersion, note: note),
                                      reply: ArtifactSaveResult.self, timeout: 30).artifact
        artifactVersions[id] = saved.version
        return saved
    }

    /// What an artifact's page remembers (its localStorage), kept on the Hermes instance for the next opening.
    public func saveArtifactPageState(_ id: String, state: [String: String], in profileId: String) async throws {
        _ = try await request(type: "artifact.state.save", profileId: profileId,
                              data: ArtifactPageStateData(artifact_id: id, state: state),
                              reply: ArtifactPageStateResult.self, timeout: 30)
    }

    // MARK: - Schedules (docs/scheduler.md)

    /// Counts "an agent's schedules changed" notices (open schedule screens reload).
    @Published public private(set) var schedulesChanges = 0
    public private(set) var lastSchedulesChange: String?

    /// Every agent's schedules, or one agent's.
    public func schedules(for profileId: String? = nil) async throws -> [ScheduleJob] {
        try await request(type: "schedules.list", profileId: profileId, data: EmptyData(),
                          reply: SchedulesListResult.self, timeout: 30).jobs
    }

    /// What Hermes understands from a schedule ("weekdays at 9am"): its words and the next times.
    public func previewSchedule(_ text: String) async throws -> SchedulePreview {
        try await request(type: "schedule.preview", data: SchedulePreviewData(schedule: text),
                          reply: SchedulePreview.self, timeout: 15)
    }

    /// A draft from the user's words ("every weekday morning, summarise my inbox"), checked with Hermes.
    public func draftSchedule(_ description: String, for profileId: String) async throws -> ScheduleDraft {
        try await request(type: "schedule.draft", profileId: profileId, data: ScheduleDraftData(description: description),
                          reply: ScheduleDraft.self, timeout: 90)
    }

    @discardableResult
    public func createSchedule(_ data: ScheduleCreateData, for profileId: String) async throws -> ScheduleJob {
        try await request(type: "schedule.create", profileId: profileId, data: data, reply: ScheduleJobResult.self, timeout: 30).job
    }

    @discardableResult
    public func updateSchedule(_ jobId: String, _ changes: ScheduleChanges, for profileId: String) async throws -> ScheduleJob {
        try await request(type: "schedule.update", profileId: profileId, data: ScheduleUpdateData(job_id: jobId, changes: changes),
                          reply: ScheduleJobResult.self, timeout: 30).job
    }

    /// `schedule.pause`, `schedule.resume` or `schedule.run` (due at the next tick).
    @discardableResult
    public func scheduleAction(_ action: String, _ jobId: String, for profileId: String) async throws -> ScheduleJob {
        try await request(type: "schedule." + action, profileId: profileId, data: ScheduleJobRef(job_id: jobId),
                          reply: ScheduleJobResult.self, timeout: 30).job
    }

    public func deleteSchedule(_ jobId: String, for profileId: String) async throws {
        _ = try await request(type: "schedule.delete", profileId: profileId, data: ScheduleJobRef(job_id: jobId),
                              reply: ScheduleDeleteResult.self, timeout: 30)
    }

    public func scheduleRuns(_ jobId: String, for profileId: String) async throws -> [ScheduleRun] {
        try await request(type: "schedule.runs", profileId: profileId, data: ScheduleJobRef(job_id: jobId),
                          reply: ScheduleRunsResult.self, timeout: 30).runs
    }

    public func scheduleOutput(_ jobId: String, run runId: String, for profileId: String) async throws -> String {
        try await request(type: "schedule.output", profileId: profileId, data: ScheduleOutputData(job_id: jobId, run_id: runId),
                          reply: ScheduleOutputResult.self, timeout: 30).text
    }

    // MARK: - Board (docs/kanban.md)

    /// Counts the instance's "something changed on a board" notices (an open board or task reloads).
    @Published public private(set) var kanbanChanges = 0
    public private(set) var lastKanbanChange: KanbanChangedData?

    public func kanbanBoard(_ board: String? = nil, archived: Bool = false) async throws -> KanbanBoardResult {
        try await request(type: "kanban.board", data: KanbanBoardRequest(board: board, archived: archived),
                          reply: KanbanBoardResult.self, timeout: 30)
    }

    public func kanbanTask(_ taskId: String, board: String?) async throws -> KanbanTaskResult {
        try await request(type: "kanban.task", data: KanbanTaskRequest(board: board, task_id: taskId),
                          reply: KanbanTaskResult.self, timeout: 30)
    }

    @discardableResult
    public func createTask(on board: String?, title: String, body: String?, assignee: String?, priority: Int,
                           waitsOn: [String] = [], triage: Bool = false) async throws -> KanbanCard {
        try await kanbanChange("kanban.create", KanbanCreateData(board: board, title: title, body: body, assignee: assignee,
                                                                priority: priority, parents: waitsOn, triage: triage))
    }

    @discardableResult
    public func editTask(_ taskId: String, on board: String?, title: String, body: String, priority: Int) async throws -> KanbanCard {
        try await kanbanChange("kanban.edit", KanbanEditData(board: board, task_id: taskId, title: title, body: body, priority: priority))
    }

    /// To another status (Hermes' rules decide; a refusal says why). `note`: why it's blocked, or what was done.
    @discardableResult
    public func moveTask(_ taskId: String, on board: String?, to status: String, note: String? = nil) async throws -> KanbanCard {
        try await kanbanChange("kanban.move", KanbanMoveData(board: board, task_id: taskId, status: status, note: note))
    }

    @discardableResult
    public func assignTask(_ taskId: String, on board: String?, to assignee: String?) async throws -> KanbanCard {
        try await kanbanChange("kanban.assign", KanbanAssignData(board: board, task_id: taskId, assignee: assignee))
    }

    @discardableResult
    public func commentOnTask(_ taskId: String, on board: String?, _ body: String) async throws -> KanbanCard {
        try await kanbanChange("kanban.comment", KanbanCommentData(board: board, task_id: taskId, body: body))
    }

    /// The task waits on `parentId` (or, with `remove`, no longer does).
    @discardableResult
    public func linkTask(_ taskId: String, on board: String?, waitsOn parentId: String, remove: Bool = false) async throws -> KanbanCard {
        try await kanbanChange("kanban.link", KanbanLinkData(board: board, task_id: taskId, parent_id: parentId, remove: remove))
    }

    /// Stops a running task; it waits as blocked.
    @discardableResult
    public func stopTask(_ taskId: String, on board: String?) async throws -> KanbanCard {
        try await kanbanChange("kanban.stop", KanbanTaskRequest(board: board, task_id: taskId))
    }

    private func kanbanChange<T: Codable>(_ type: String, _ data: T) async throws -> KanbanCard {
        try await request(type: type, data: data, reply: KanbanChangeResult.self, timeout: 30).task
    }

    /// Direct voice (docs/voice.md §4): replies whose sound is streamed while it's made.
    public private(set) var streamingReplies: Set<String> = []
    /// Streamed sound as it arrives (a hands-free call plays it at once).
    var onVoiceStream: ((VoiceStreamData) -> Void)?

    public func directVoice(for profileId: String) async throws -> DirectVoiceInfo {
        try await request(type: "voice.direct.get", profileId: profileId, data: EmptyData(),
                          reply: DirectVoiceInfo.self, timeout: 30)
    }

    /// Saves the choice; `key` (provider, value) saves a key on the instance ("" clears it).
    public func setDirectVoice(_ settings: DirectVoiceSettings, key: (provider: String, value: String)? = nil,
                               for profileId: String) async throws -> DirectVoiceInfo {
        try await request(type: "voice.direct.set", profileId: profileId,
                          data: DirectVoiceSetData(settings: settings, key: key.map { DirectVoiceKey(provider: $0.provider, value: $0.value) }),
                          reply: DirectVoiceInfo.self, timeout: 30)
    }

    /// A short sample in the chosen direct voice, on the phone.
    public func testDirectVoice(for profileId: String) async throws -> URL {
        let got = try await request(type: "voice.direct.test", profileId: profileId, data: EmptyData(),
                                    reply: DirectVoiceTestResult.self, timeout: 60)
        return try await fileURL(for: got.file)
    }

    /// Voice mode: replies the instance is making into voice notes, by message id (style, and
    /// why their audio can't play, if so).
    @Published public private(set) var voiceReplies: [String: (style: String, problem: String?)] = [:]

    // MARK: - An agent's tools in Lekora chats (docs/agent-tools.md)

    public func agentTools(for profileId: String) async throws -> AgentToolsData {
        try await request(type: "agent.tools.get", profileId: profileId, data: EmptyData(),
                          reply: AgentToolsData.self, timeout: 30)
    }

    public func setAgentTools(_ changes: [String: Bool], for profileId: String) async throws -> AgentToolsData {
        try await request(type: "agent.tools.set", profileId: profileId, data: AgentToolsChange(changes: changes),
                          reply: AgentToolsData.self, timeout: 60)
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

    /// A reply in the agent's Hermes voice: its audio file(s) on the phone, in order.
    public func hermesSpeech(for seq: Int, in profileId: String) async throws -> [URL] {
        let got = try await request(type: "voice.speak", profileId: profileId, data: VoiceSpeakData(seq: seq),
                                    reply: VoiceSpeakResult.self, timeout: 180)
        var urls: [URL] = []
        for file in got.files ?? [got.file] { urls.append(try await fileURL(for: file)) }
        return urls
    }

    /// Personality voice: the words of each spoken part as it arrives, by message id and part.
    @Published public private(set) var liveScripts: [String: [Int: String]] = [:]

    /// Voice mode: spoken parts of replies as they arrive, by message id, in order.
    @Published public private(set) var liveSpeech: [String: [ChatFile]] = [:]

    /// Turns voice mode on or off for an agent (its replies as voice notes; docs/voice.md §2).
    public func setVoiceReplies(_ mode: String, for profileId: String) async throws {
        var settings = voiceSettings[profileId] ?? .standard
        settings.speak = mode
        try await setVoiceSettings(settings, for: profileId)
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
        case "voice.reply":
            guard let envelope = try? decoder.decode(Envelope<VoiceReplyData>.self, from: data) else { return }
            let known = voiceReplies[envelope.data.message_id]
            voiceReplies[envelope.data.message_id] = (envelope.data.style, envelope.data.problem ?? known?.problem)
            if envelope.data.streaming == true { streamingReplies.insert(envelope.data.message_id) }
        case "artifact.changed":
            guard let envelope = try? decoder.decode(Envelope<ArtifactChangedData>.self, from: data) else { return }
            artifactVersions[envelope.data.artifact.artifact_id] = envelope.data.artifact.version
        case "schedules.changed":
            lastSchedulesChange = (try? decoder.decode(Envelope<EmptyData>.self, from: data))?.profile_id
            schedulesChanges += 1
        case "kanban.changed":
            guard let envelope = try? decoder.decode(Envelope<KanbanChangedData>.self, from: data) else { return }
            lastKanbanChange = envelope.data
            kanbanChanges += 1
        case "voice.stream":
            guard let envelope = try? decoder.decode(Envelope<VoiceStreamData>.self, from: data) else { return }
            onVoiceStream?(envelope.data)
        case "voice.segment":
            guard let envelope = try? decoder.decode(Envelope<VoiceSegmentData>.self, from: data) else { return }
            if let inline = envelope.data.data, cachedFileURL(envelope.data.file) == nil,
               let bytes = Data(base64Encoded: inline) {
                // Came with the segment: kept like a fetched file, so it plays straight away.
                let target = localFileURL(envelope.data.file)
                try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? bytes.write(to: target, options: .atomic)
            }
            var parts = liveSpeech[envelope.data.message_id] ?? []
            if envelope.data.index >= parts.count { parts.append(envelope.data.file) }
            liveSpeech[envelope.data.message_id] = parts
            if let script = envelope.data.script {
                var scripts = liveScripts[envelope.data.message_id] ?? [:]
                scripts[envelope.data.index] = script
                liveScripts[envelope.data.message_id] = scripts
            }
        case "voice.settings.changed":
            // Changed on another phone.
            guard let envelope = try? decoder.decode(Envelope<VoiceSettingsData>.self, from: data),
                  let profileId = envelope.profile_id else { return }
            voiceSettings[profileId] = envelope.data.settings
        case "instance.changed":
            // Renamed from another phone.
            guard let envelope = try? decoder.decode(Envelope<InstanceNameData>.self, from: data) else { return }
            applyInstanceName(envelope.data.instance_name)
            if let name = envelope.data.user_name { userName = name }
        case "groups.changed":
            guard let envelope = try? decoder.decode(Envelope<GroupsListData>.self, from: data) else { return }
            applyGroups(envelope.data.groups)
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
                transcript: envelope.data.transcript,
                spoken: envelope.data.spoken,
                voicing: envelope.data.voicing,
                voiceProblem: envelope.data.voice_problem,
                voiceKey: envelope.data.voice_key,
                spokenText: envelope.data.spoken_text,
                artifact: envelope.data.artifact,
                about: envelope.data.about,
                review: envelope.data.review,
                session: envelope.data.session,
                delegation: envelope.data.delegation,
                speaker: envelope.data.speaker
            )
            if let session = envelope.data.session, envelope.data.seq >= (timeline.newestSeq(for: profileId) ?? 0) {
                // The newest message is in the current conversation (after New Chat, a resume, or Hermes' own reset).
                if currentChat[profileId] != session { currentChat[profileId] = session }
            }
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
                                text: envelope.data.text, speaker: envelope.data.speaker)
        case "chat.typing":
            guard let envelope = try? decoder.decode(Envelope<ChatTypingData>.self, from: data) else { return }
            var status = envelope.data.status
            if let speaker = envelope.data.speaker {
                // A group: who is working ("Coder is searching the web…"; docs/group-chats.md).
                let name = agentName(speaker)
                let said = status?.trimmingCharacters(in: .whitespaces) ?? ""
                status = said.hasPrefix("is ") || said.hasPrefix("has ") ? "\(name) \(said)"
                    : said.isEmpty ? "\(name) is thinking…" : "\(name): \(said)"
            }
            setActivity(envelope.profile_id ?? activeProfileId,
                        active: envelope.data.active, status: status)
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

    // MARK: - Your name (docs/your-name.md)

    /// What this instance's agents call you: "" when not chosen yet, nil from an older plugin
    /// (or before connecting). Kept on the instance, so a new phone gets it too.
    @Published public private(set) var userName: String?

    public func setUserName(_ name: String) async throws {
        let result = try await request(type: "user.name.set", profileId: nil, data: UserNameSetData(name: name),
                                       reply: UserNameData.self, timeout: 10)
        userName = result.user_name
    }

    /// A hands-free diagnostics line, written to the instance's log (docs/voice.md §3).
    func reportVoiceLog(_ line: String, profileId: String) {
        guard case .connected = state, let wsTask = webSocketTask, let instanceId = savedHost?.instanceId else { return }
        let envelope = Envelope(type: "voice.log", instance_id: instanceId, profile_id: profileId,
                                data: VoiceLogData(line: String(line.prefix(300))))
        Task { [weak self] in try? await self?.send(envelope, on: wsTask) }
    }

    /// A hands-free turn's timing, written to the instance's log next to its own (docs/voice.md §3).
    func reportVoiceTiming(_ timing: VoiceTimingData, profileId: String) {
        guard case .connected = state, let wsTask = webSocketTask, let instanceId = savedHost?.instanceId else { return }
        let envelope = Envelope(type: "voice.timing", instance_id: instanceId, profile_id: profileId, data: timing)
        Task { [weak self] in try? await self?.send(envelope, on: wsTask) }
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
