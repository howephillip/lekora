import Foundation

/// Where pairing credentials live. `KeychainManager` in the app; an in-memory store in tests.
public protocol CredentialStore: AnyObject {
    func save(key: String, value: String) throws
    func get(key: String) throws -> String?
    func delete(key: String) throws
}

extension KeychainManager: CredentialStore {}

/// Everything needed to reconnect to a paired host without the setup wizard.
public struct SavedHost: Equatable {
    public let instanceId: String
    public let instanceName: String
    public let deviceId: String
    public let deviceToken: String
    /// Candidate `ws://` addresses, tried in parallel; the one that worked last is first.
    public let endpoints: [String]

    private enum Key {
        static let instanceId = "instance_id"
        static let instanceName = "instance_name"
        static let deviceId = "device_id"
        static let deviceToken = "device_token"
        static let endpoints = "endpoints"
        static let all = [instanceId, instanceName, deviceId, deviceToken, endpoints]
    }

    public init(instanceId: String, instanceName: String, deviceId: String, deviceToken: String, endpoints: [String]) {
        self.instanceId = instanceId
        self.instanceName = instanceName
        self.deviceId = deviceId
        self.deviceToken = deviceToken
        self.endpoints = endpoints
    }

    /// Returns nil unless every piece is present. Pairings made before addresses were
    /// saved have no endpoints, so they count as "not paired" and show the wizard.
    public static func load(from store: CredentialStore) -> SavedHost? {
        func value(_ key: String) -> String? {
            guard let stored = try? store.get(key: key), !stored.isEmpty else { return nil }
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
            endpoints: endpoints
        )
    }

    public func save(to store: CredentialStore) throws {
        try store.save(key: Key.instanceId, value: instanceId)
        try store.save(key: Key.instanceName, value: instanceName)
        try store.save(key: Key.deviceId, value: deviceId)
        try store.save(key: Key.deviceToken, value: deviceToken)
        try store.save(key: Key.endpoints, value: endpoints.joined(separator: "\n"))
    }

    public static func clear(from store: CredentialStore) {
        for key in Key.all {
            try? store.delete(key: key)
        }
    }

    /// Winning route first, then the rest, without duplicates.
    public static func orderedEndpoints(preferred: URL?, _ lists: [String]...) -> [String] {
        var seen = Set<String>()
        let all = [preferred?.absoluteString].compactMap { $0 } + lists.flatMap { $0 }
        return all.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
