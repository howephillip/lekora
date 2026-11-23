import Foundation

/// Where pairing credentials live. `KeychainManager` in the app; an in-memory store in tests.
public protocol CredentialStore: AnyObject {
    func save(key: String, value: String) throws
    func get(key: String) throws -> String?
    func delete(key: String) throws
}

extension KeychainManager: CredentialStore {}

/// Everything needed to reconnect to a paired host without the setup wizard.
/// The phone can be paired with several Hermes computers (docs/multiple-instances.md):
/// each one's details are kept under its own keys, `host.<instance id>.<field>`, and the
/// key `hosts` lists them in the order they were paired.
public struct SavedHost: Equatable {
    public let instanceId: String
    /// The computer's name, as the host reports it (it can be renamed from the app).
    public var instanceName: String
    public let deviceId: String
    public let deviceToken: String
    /// Candidate `ws://` addresses, tried in parallel; the one that worked last is first. Refreshed on every
    /// connection from the instance's current addresses (docs/tailscale.md).
    public var endpoints: [String]
    /// Fingerprint of the host's certificate; connections accept only this certificate.
    public let certPin: String?
    /// Agents (profile ids) chosen for this phone; nil until the user has chosen.
    public var enabledProfileIds: [String]?
    /// The agent the chat screen last showed.
    public var activeProfileId: String?

    private enum Key {
        static let instanceId = "instance_id"
        static let instanceName = "instance_name"
        static let deviceId = "device_id"
        static let deviceToken = "device_token"
        static let endpoints = "endpoints"
        static let enabledProfiles = "enabled_profiles"
        static let activeProfile = "active_profile"
        static let certPin = "cert_pin"
        static let all = [instanceId, instanceName, deviceId, deviceToken, endpoints, enabledProfiles, activeProfile, certPin]
        /// The paired computers' instance ids, newline-separated, oldest first.
        static let hosts = "hosts"

        static func of(_ instanceId: String, _ field: String) -> String { "host.\(instanceId).\(field)" }
    }

    public init(instanceId: String, instanceName: String, deviceId: String, deviceToken: String, endpoints: [String],
                certPin: String? = nil, enabledProfileIds: [String]? = nil, activeProfileId: String? = nil) {
        self.certPin = certPin
        self.instanceId = instanceId
        self.instanceName = instanceName
        self.deviceId = deviceId
        self.deviceToken = deviceToken
        self.endpoints = endpoints
        self.enabledProfileIds = enabledProfileIds
        self.activeProfileId = activeProfileId
    }

    // MARK: - Every paired computer

    /// The paired computers, oldest pairing first. A pairing from before several computers
    /// (stored under the plain keys) is moved to the new layout the first time.
    public static func loadAll(from store: CredentialStore) -> [SavedHost] {
        migrateSingleHost(in: store)
        return pairedIds(in: store).compactMap { load(instanceId: $0, from: store) }
    }

    /// The first paired computer (tests, and code that only needs one).
    public static func load(from store: CredentialStore) -> SavedHost? {
        loadAll(from: store).first
    }

    /// Returns nil unless every piece is present. Pairings made before addresses were
    /// saved have no endpoints, so they count as "not paired" and show the wizard.
    public static func load(instanceId: String, from store: CredentialStore) -> SavedHost? {
        read(from: store) { Key.of(instanceId, $0) }
    }

    public func save(to store: CredentialStore) throws {
        let key = { Key.of(instanceId, $0) }
        try store.save(key: key(Key.instanceId), value: instanceId)
        try store.save(key: key(Key.instanceName), value: instanceName)
        try store.save(key: key(Key.deviceId), value: deviceId)
        try store.save(key: key(Key.deviceToken), value: deviceToken)
        try store.save(key: key(Key.endpoints), value: endpoints.joined(separator: "\n"))
        if let certPin {
            try store.save(key: key(Key.certPin), value: certPin)
        } else {
            try store.delete(key: key(Key.certPin))
        }
        try saveProfileChoice(to: store)
        var ids = Self.pairedIds(in: store)
        if !ids.contains(instanceId) {
            ids.append(instanceId)
            try store.save(key: Key.hosts, value: ids.joined(separator: "\n"))
        }
    }

    /// Persists just the agent choice (after "Choose Agents" or switching agents).
    public func saveProfileChoice(to store: CredentialStore) throws {
        let key = { Key.of(instanceId, $0) }
        if let enabledProfileIds, !enabledProfileIds.isEmpty {
            try store.save(key: key(Key.enabledProfiles), value: enabledProfileIds.joined(separator: "\n"))
        } else {
            try store.delete(key: key(Key.enabledProfiles))
        }
        if let activeProfileId {
            try store.save(key: key(Key.activeProfile), value: activeProfileId)
        } else {
            try store.delete(key: key(Key.activeProfile))
        }
    }

    /// Persists just the addresses (the instance sends its current ones on every connection).
    public func saveEndpoints(to store: CredentialStore) throws {
        try store.save(key: Key.of(instanceId, Key.endpoints), value: endpoints.joined(separator: "\n"))
    }

    /// Persists just the computer's name (renamed in the app or on another phone).
    public func saveName(to store: CredentialStore) throws {
        try store.save(key: Key.of(instanceId, Key.instanceName), value: instanceName)
    }

    /// Forgets one computer; the others stay paired.
    public static func clear(instanceId: String, from store: CredentialStore) {
        for field in Key.all {
            try? store.delete(key: Key.of(instanceId, field))
        }
        let ids = pairedIds(in: store).filter { $0 != instanceId }
        if ids.isEmpty {
            try? store.delete(key: Key.hosts)
        } else {
            try? store.save(key: Key.hosts, value: ids.joined(separator: "\n"))
        }
    }

    /// Forgets every computer.
    public static func clear(from store: CredentialStore) {
        migrateSingleHost(in: store)
        for id in pairedIds(in: store) { clear(instanceId: id, from: store) }
    }

    private static func pairedIds(in store: CredentialStore) -> [String] {
        guard let list = try? store.get(key: Key.hosts) else { return [] }
        return list.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    private static func read(from store: CredentialStore, key: (String) -> String) -> SavedHost? {
        func value(_ field: String) -> String? {
            guard let stored = try? store.get(key: key(field)), !stored.isEmpty else { return nil }
            return stored
        }
        guard let instanceId = value(Key.instanceId),
              let deviceId = value(Key.deviceId),
              let deviceToken = value(Key.deviceToken),
              let endpointList = value(Key.endpoints) else {
            return nil
        }
        let endpoints = endpointList.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        guard !endpoints.isEmpty else { return nil }
        return SavedHost(
            instanceId: instanceId,
            instanceName: value(Key.instanceName) ?? "Hermes",
            deviceId: deviceId,
            deviceToken: deviceToken,
            endpoints: endpoints,
            certPin: value(Key.certPin),
            enabledProfileIds: value(Key.enabledProfiles).map { $0.split(separator: "\n").map(String.init) },
            activeProfileId: value(Key.activeProfile)
        )
    }

    /// Moves a pairing saved under the plain keys (one computer only) to its own keys.
    /// An unusable old pairing (no addresses) is just removed.
    private static func migrateSingleHost(in store: CredentialStore) {
        guard (try? store.get(key: Key.instanceId)) != nil else { return }
        if let old = read(from: store, key: { $0 }) {
            guard (try? old.save(to: store)) != nil else { return }  // keep the old keys if saving failed
        }
        for field in Key.all { try? store.delete(key: field) }
    }

    /// Winning route first, then the rest, without duplicates.
    public static func orderedEndpoints(preferred: URL?, _ lists: [String]...) -> [String] {
        var seen = Set<String>()
        let all = [preferred?.absoluteString].compactMap { $0 } + lists.flatMap { $0 }
        return all.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// How the phone reaches an instance (docs/tailscale.md): its home network, Tailscale, or the internet.
public enum LKRoute: Equatable {
    case home, tailscale, internet

    public static func of(_ endpoint: String) -> LKRoute {
        guard let host = URL(string: endpoint)?.host?.lowercased() else { return .internet }
        if host.hasSuffix(".ts.net") || inTailnet(host) { return .tailscale }
        if host.hasSuffix(".local") || isPrivate(host) { return .home }
        return .internet
    }

    public var label: String {
        switch self {
        case .home: return "Home network"
        case .tailscale: return "Tailscale"
        case .internet: return "Internet"
        }
    }

    /// Tailscale's address range, 100.64.0.0/10.
    static func inTailnet(_ host: String) -> Bool {
        let parts = host.split(separator: ".").compactMap { UInt8($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }

    static func isPrivate(_ host: String) -> Bool {
        let parts = host.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 10 || (parts[0] == 172 && (16...31).contains(parts[1])) || (parts[0] == 192 && parts[1] == 168)
    }

    /// True when this phone has a Tailscale address right now (Tailscale is on and connected).
    public static func phoneOnTailscale() -> Bool {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return false }
        defer { freeifaddrs(list) }
        for item in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = item.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var text = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &text, socklen_t(text.count), nil, 0, NI_NUMERICHOST) == 0,
               inTailnet(String(cString: text)) {
                return true
            }
        }
        return false
    }

    /// Tailscale's app (opened if installed), else its App Store page.
    public static let tailscaleApp = URL(string: "tailscale://")!
    public static let tailscaleAppStore = URL(string: "https://apps.apple.com/app/tailscale/id1470499037")!
}
