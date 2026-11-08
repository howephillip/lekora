import Foundation

/// One bubble in the chat: either something this phone sent, or a message from the host.
public struct ChatEntry: Identifiable, Equatable {
    public enum Role: Equatable {
        case user
        case agent
        /// Hermes' own notices ("Gateway online…", "Background task finished…").
        case system
    }

    public enum Status: Equatable {
        case sending
        case sent
        case failed(String)
        /// An agent reply still being written (live text from the host, not saved yet).
        case streaming
    }

    /// The `chat.send` envelope id for messages sent from this phone, or "seq-<n>" for host messages.
    public let id: String
    public let profileId: String
    public let role: Role
    public var text: String
    /// Host sequence number; nil for our own messages until the host reports them back.
    public var seq: Int?
    public var status: Status

    public init(id: String, profileId: String, role: Role, text: String, seq: Int? = nil, status: Status = .sent) {
        self.id = id
        self.profileId = profileId
        self.role = role
        self.text = text
        self.seq = seq
        self.status = status
    }
}

/// Chronological chat history across all profiles.
///
/// The host never echoes a `chat.send` back to the phone that sent it, so outgoing
/// messages are added locally. After a reconnect the host may replay that same
/// message (with its seq); `applyIncoming` matches it to the local copy instead of
/// showing it twice, and ignores any seq it has already seen.
public struct ChatTimeline: Equatable {
    public private(set) var entries: [ChatEntry] = []

    public init() {}

    public func entries(for profileId: String) -> [ChatEntry] {
        entries.filter { $0.profileId == profileId }
    }

    /// Drops a deleted agent's messages (the host keeps them in its backup).
    public mutating func removeEntries(for profileId: String) {
        entries.removeAll { $0.profileId == profileId }
    }

    /// Live text of a reply being written. Empty text drops the bubble.
    public mutating func applyDraft(draftId: String, profileId: String, text: String) {
        if let index = entries.firstIndex(where: { $0.id == draftId }) {
            guard entries[index].status == .streaming else { return }  // already saved: ignore late drafts
            if text.isEmpty {
                entries.remove(at: index)
            } else {
                entries[index].text = text
            }
            return
        }
        guard !text.isEmpty else { return }
        entries.append(ChatEntry(id: draftId, profileId: profileId, role: .agent, text: text, status: .streaming))
    }

    /// Live bubbles are previews: after a reconnect the host's replay is the truth.
    public mutating func dropUnfinishedReplies() {
        entries.removeAll { $0.status == .streaming }
    }

    public mutating func addOutgoing(id: String, profileId: String, text: String) {
        entries.append(ChatEntry(id: id, profileId: profileId, role: .user, text: text, status: .sending))
    }

    public mutating func markSent(id: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }),
              entries[index].status == .sending else { return }
        entries[index].status = .sent
    }

    /// Returns false when `id` isn't one of our messages (e.g. an error about something else).
    @discardableResult
    public mutating func markFailed(id: String, reason: String) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id && $0.role == .user }) else { return false }
        entries[index].status = .failed(reason)
        return true
    }

    public mutating func applyIncoming(seq: Int, profileId: String, role: String, text: String,
                                       draftId: String? = nil) {
        if let index = entries.firstIndex(where: { $0.seq == seq }) {
            // Seen before (replay) — or a correction the agent made after saving it.
            if entries[index].text != text { entries[index].text = text }
            return
        }

        // The saved version of a live reply: replace the bubble in place.
        if let draftId, let index = entries.firstIndex(where: { $0.id == draftId }) {
            entries[index].seq = seq
            entries[index].text = text
            entries[index].status = .sent
            return
        }

        if role == "user",
           let index = entries.firstIndex(where: {
               $0.role == .user && $0.seq == nil && $0.profileId == profileId && $0.text == text
           }) {
            entries[index].seq = seq
            entries[index].status = .sent
            return
        }

        entries.append(ChatEntry(
            id: "seq-\(seq)",
            profileId: profileId,
            role: role == "user" ? .user : (role == "system" ? .system : .agent),
            text: text,
            seq: seq
        ))
    }
}
