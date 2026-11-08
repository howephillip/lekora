import Foundation

/// What the phone keeps of one host's chats between launches (docs/chat-history.md).
/// A cache only: the host has everything, and a new phone gets it back from there.
public struct ChatCache: Codable, Equatable {
    public var instanceId: String
    /// Highest change number seen: the next `hello` asks only for what changed after it.
    public var rev: Int
    /// Highest seq seen (for hosts from before chat history).
    public var lastSeq: Int
    public var entries: [ChatEntry]
    public var completeProfiles: [String]
    /// Read markers per agent, and whether the host keeps them.
    public var read: [String: Int]
    public var hostTracksRead: Bool
    /// The host's agents when last connected, so the chat can show before reconnecting.
    public var profiles: [ProfileData]

    /// Messages kept per agent; older ones load from the host when scrolling up.
    public static let messagesPerAgent = 300
}

/// Reads and writes `ChatCache` files: one per host, in the app's private storage.
public struct ChatCacheStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// Application Support/Lekora (iOS keeps it private to the app).
    public static var standard: ChatCacheStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return ChatCacheStore(directory: base.appendingPathComponent("Lekora", isDirectory: true))
    }

    private func url(for instanceId: String) -> URL {
        let safe = instanceId.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        return directory.appendingPathComponent("chat-\(safe).json")
    }

    public func load(instanceId: String) -> ChatCache? {
        guard let data = try? Data(contentsOf: url(for: instanceId)),
              let cache = try? JSONDecoder().decode(ChatCache.self, from: data),
              cache.instanceId == instanceId else { return nil }
        return cache
    }

    public func save(_ cache: ChatCache) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(cache)
            try data.write(to: url(for: cache.instanceId), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            // A cache that can't be written only costs a fuller catch-up next launch.
        }
    }

    public func delete(instanceId: String) {
        try? FileManager.default.removeItem(at: url(for: instanceId))
    }
}
