import Foundation
import Combine

/// One of your agents, on one of your computers: two computers can both have "default".
public struct AgentKey: Hashable, Codable, Sendable {
    public let instanceId: String
    public let profileId: String
}

/// Every paired Hermes computer, each with its own connection (docs/multiple-computers.md).
/// One computer going offline doesn't affect the others.
@MainActor
public final class HostsModel: ObservableObject {
    /// Paired computers, oldest pairing first.
    @Published public private(set) var clients: [GatewayClient] = []
    /// A client for pairing the next computer (setup, or "Add Computer").
    @Published public private(set) var pairing: GatewayClient
    /// Something to tell the user about a computer that was removed (e.g. it no longer
    /// knows this phone).
    @Published public var notice: String?

    private let makeClient: (GatewayClient.Start) -> GatewayClient
    private var forwarding: [ObjectIdentifier: AnyCancellable] = [:]

    public init(keychain: CredentialStore = KeychainManager.shared,
                makeClient: ((GatewayClient.Start) -> GatewayClient)? = nil) {
        let make = makeClient ?? { start in GatewayClient(keychain: keychain, cacheStore: .standard, start: start) }
        self.makeClient = make
        self.pairing = make(.fresh)
        for host in SavedHost.loadAll(from: keychain) { add(make(.saved(host))) }
        // A pairing from before encryption is cleared by its client: say why on the setup screen.
        for client in clients where client.savedHost == nil {
            if case .error(let message) = client.state { notice = message }
        }
        clients.removeAll { $0.savedHost == nil }
        preparePairing()
    }

    // MARK: - Lookup

    public func client(for instanceId: String) -> GatewayClient? {
        clients.first { $0.savedHost?.instanceId == instanceId }
    }

    /// More than one computer: agents show which computer they're on.
    public var hasSeveral: Bool { clients.count > 1 }

    /// Every agent this phone uses, on every computer, most recent conversation first
    /// (each computer's own order breaks ties: agents with no messages keep it).
    public var agentsByRecency: [(key: AgentKey, client: GatewayClient, profile: ProfileData)] {
        let all = clients.flatMap { client in
            client.agentsByRecency.enumerated().map { index, profile in
                (key: AgentKey(instanceId: client.savedHost?.instanceId ?? "", profileId: profile.profile_id),
                 client: client, profile: profile, index: index, newest: client.newestActivity(for: profile.profile_id))
            }
        }
        return all.sorted { a, b in
            switch (a.newest, b.newest) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default:
                if a.index != b.index { return a.index < b.index }
                return (clients.firstIndex { $0 === a.client } ?? 0) < (clients.firstIndex { $0 === b.client } ?? 0)
            }
        }.map { (key: $0.key, client: $0.client, profile: $0.profile) }
    }

    // MARK: - Connections

    /// Connects every computer that isn't connected (launch, coming back to the app).
    public func resumeAll() async {
        await withTaskGroup(of: Void.self) { group in
            for client in clients {
                group.addTask { await client.resumeSavedSession() }
            }
        }
    }

    public func saveCachesNow() {
        for client in clients { client.saveCacheNow() }
    }

    /// A `lekora-pair://` link (scanned, pasted or opened). Pairing a computer that's
    /// already paired replaces its old pairing.
    public func handlePairingPayload(_ payload: String) {
        pairing.handlePairingPayload(payload)
    }

    /// Asks the computer to revoke this phone, then forgets it here. Returns a message
    /// when the computer couldn't be reached.
    @discardableResult
    public func forget(_ client: GatewayClient) async -> String? {
        let name = client.savedHost?.instanceName ?? "the computer"
        let outcome = await client.forgetHost()
        remove(client)
        if outcome == .hostUnreachable {
            return "This phone forgot \(name), but couldn't reach it to remove this phone from its list. On that computer, `hermes lekora devices` can revoke it."
        }
        return nil
    }

    // MARK: - Private

    private func preparePairing() {
        pairing.onPaired = { [weak self] client in self?.paired(client) }
    }

    /// A pairing succeeded: the computer joins the list (replacing an older pairing of the
    /// same computer), and a new client waits for the next one.
    private func paired(_ client: GatewayClient) {
        guard let id = client.savedHost?.instanceId else { return }
        if let old = self.client(for: id), old !== client {
            old.shutDown()
            remove(old)
        }
        client.onPaired = nil
        add(client)
        notice = nil
        pairing = makeClient(.fresh)
        preparePairing()
    }

    private func add(_ client: GatewayClient) {
        clients.append(client)
        client.palettesTakenElsewhere = { [weak self, weak client] in
            guard let self, let client else { return [] }
            return self.palettesBefore(client)
        }
        // Views watch this model; pass each computer's changes on, and drop a computer
        // that forgot itself (it no longer knows this phone).
        forwarding[ObjectIdentifier(client)] = client.objectWillChange.sink { [weak self, weak client] _ in
            self?.objectWillChange.send()
            Task { @MainActor [weak self, weak client] in
                guard let self, let client, self.clients.contains(where: { $0 === client }),
                      client.savedHost == nil, !client.isForgetting else { return }
                if case .error(let message) = client.state { self.notice = message }
                self.remove(client)
            }
        }
    }

    private func remove(_ client: GatewayClient) {
        forwarding[ObjectIdentifier(client)] = nil
        clients.removeAll { $0 === client }
    }

    private func palettesBefore(_ client: GatewayClient) -> Set<Int> {
        guard let index = clients.firstIndex(where: { $0 === client }) else { return [] }
        return Set(clients[..<index].flatMap { $0.avatarPalettes.values })
    }
}
