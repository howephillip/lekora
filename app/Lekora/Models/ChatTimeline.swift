import Foundation

/// One bubble in the chat: either something this phone sent, or a message from the host.
public struct ChatEntry: Identifiable, Equatable, Codable {
    public enum Role: Equatable, Codable {
        case user
        case agent
        /// Hermes' own notices ("Gateway online…", "Background task finished…").
        case system
        /// An approval or question card from the agent (docs/prompts.md).
        case prompt
    }

    public enum Status: Equatable, Codable {
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
    /// When the host saved it (or when it was sent from here); nil for messages cached
    /// before hosts sent times.
    public var date: Date?
    /// For `.prompt` entries.
    public var card: PromptCard?
    /// Photos and files with the message (docs/files.md); nil = none.
    public var files: [ChatFile]?
    /// A voice note (its recording is `files[0]`), and what Hermes heard (docs/voice.md).
    public var voice: VoiceDetails?
    public var transcript: String?

    public init(id: String, profileId: String, role: Role, text: String, seq: Int? = nil,
                status: Status = .sent, date: Date? = nil, card: PromptCard? = nil, files: [ChatFile]? = nil,
                voice: VoiceDetails? = nil, transcript: String? = nil) {
        self.files = files
        self.voice = voice
        self.transcript = transcript
        self.id = id
        self.profileId = profileId
        self.role = role
        self.text = text
        self.seq = seq
        self.status = status
        self.date = date
        self.card = card
    }
}

/// Chat history across all profiles, in host order (`seq`); messages not saved by the host
/// yet (sending, live replies) come after.
///
/// Outgoing messages are added locally straight away. The host sends each one back with its
/// seq and `client_id` (the `chat.send` id); `applyIncoming` matches it to the local copy
/// instead of showing it twice, and updates any seq it has already seen.
public struct ChatTimeline: Equatable {
    public private(set) var entries: [ChatEntry] = []
    /// Agents whose whole history is here (no older page left on the host).
    public private(set) var completeProfiles: Set<String> = []

    public init() {}

    public init(entries: [ChatEntry], completeProfiles: Set<String> = []) {
        self.entries = entries
        self.completeProfiles = completeProfiles
    }

    /// The oldest saved message of an agent held here.
    public func oldestSeq(for profileId: String) -> Int? {
        entries.lazy.filter { $0.profileId == profileId }.compactMap(\.seq).first
    }

    public func newestSeq(for profileId: String) -> Int? {
        entries.reversed().lazy.filter { $0.profileId == profileId }.compactMap(\.seq).first
    }

    /// The host sent each agent's newest messages instead of what changed: drop the saved
    /// messages held here (unsent ones and live replies stay).
    public mutating func replaceSavedWithRecent() {
        entries.removeAll { $0.seq != nil }
        completeProfiles = []
    }

    /// A page of older messages from the host (scrolling up).
    public mutating func applyPage(profileId: String, messages: [ChatMessageData], hasMore: Bool) {
        for message in messages {
            applyIncoming(seq: message.seq, profileId: profileId, role: message.role,
                          text: message.text, clientId: message.client_id,
                          date: message.date, card: message.card, files: message.files,
                          voice: message.voice, transcript: message.transcript, isPage: true)
        }
        if !hasMore { completeProfiles.insert(profileId) }
    }

    /// What the phone keeps between launches: saved messages only, the newest `perProfile`
    /// of each agent. An agent trimmed here is no longer complete.
    public func cacheSnapshot(perProfile: Int) -> ChatTimeline {
        var kept: [ChatEntry] = []
        var counts: [String: Int] = [:]
        var trimmed: Set<String> = []
        for entry in entries.reversed() where entry.seq != nil && entry.status == .sent {
            let count = counts[entry.profileId, default: 0]
            if count >= perProfile {
                trimmed.insert(entry.profileId)
                continue
            }
            counts[entry.profileId] = count + 1
            kept.append(entry)
        }
        return ChatTimeline(entries: kept.reversed(), completeProfiles: completeProfiles.subtracting(trimmed))
    }

    public func entries(for profileId: String) -> [ChatEntry] {
        entries.filter { $0.profileId == profileId }
    }

    /// Drops a deleted agent's messages (the host keeps them in its backup).
    public mutating func removeEntries(for profileId: String) {
        entries.removeAll { $0.profileId == profileId }
        completeProfiles.remove(profileId)
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
        entries.append(ChatEntry(id: draftId, profileId: profileId, role: .agent, text: text,
                                 status: .streaming, date: Date()))
    }

    /// Live bubbles are previews: after a reconnect the host's replay is the truth.
    public mutating func dropUnfinishedReplies() {
        entries.removeAll { $0.status == .streaming }
    }

    public mutating func addOutgoing(id: String, profileId: String, text: String, files: [ChatFile]? = nil,
                                     voice: VoiceDetails? = nil) {
        entries.append(ChatEntry(id: id, profileId: profileId, role: .user, text: text,
                                 status: .sending, date: Date(), files: files, voice: voice))
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

    /// - Parameter isPage: from a page of older messages, which may come before what's here.
    public mutating func applyIncoming(seq: Int, profileId: String, role: String, text: String,
                                       draftId: String? = nil, clientId: String? = nil,
                                       date: Date? = nil, card: PromptCard? = nil, files: [ChatFile]? = nil,
                                       voice: VoiceDetails? = nil, transcript: String? = nil,
                                       isPage: Bool = false) {
        if let index = entries.firstIndex(where: { $0.seq == seq }) {
            // Seen before (replay) — or a correction the agent made after saving it.
            if entries[index].text != text { entries[index].text = text }
            if let files, entries[index].files != files { entries[index].files = files }
            if let voice, entries[index].voice != voice { entries[index].voice = voice }
            if let transcript, entries[index].transcript != transcript { entries[index].transcript = transcript }
            if let date, entries[index].date != date { entries[index].date = date }
            if let card, entries[index].card != card { entries[index].card = card }  // a card's new state
            return
        }

        // The saved version of a live reply: replace the bubble in place.
        if let draftId, let index = entries.firstIndex(where: { $0.id == draftId }) {
            entries[index].seq = seq
            entries[index].text = text
            if let files { entries[index].files = files }
            entries[index].status = .sent
            if let date { entries[index].date = date }
            settle(at: index)
            return
        }

        // Our own message coming back with its seq: by its chat.send id, else by text.
        if role == "user",
           let index = entries.firstIndex(where: { clientId != nil && $0.id == clientId && $0.seq == nil })
            ?? entries.firstIndex(where: {
               $0.role == .user && $0.seq == nil && $0.profileId == profileId && $0.text == text
           }) {
            entries[index].seq = seq
            if let files { entries[index].files = files }
            if let voice { entries[index].voice = voice }
            if let transcript { entries[index].transcript = transcript }
            if entries[index].status != .sent { entries[index].status = .sent }
            if let date { entries[index].date = date }
            settle(at: index)
            return
        }

        // A correction to a message older than what's held for an agent whose earlier
        // history isn't loaded: skip it rather than leave a gap (its page will carry it).
        if !isPage, !completeProfiles.contains(profileId),
           let oldest = oldestSeq(for: profileId), seq < oldest {
            return
        }

        let entry = ChatEntry(
            id: "seq-\(seq)",
            profileId: profileId,
            role: Self.role(role, card: card),
            text: text,
            seq: seq,
            date: date,
            card: card,
            files: files,
            voice: voice,
            transcript: transcript
        )
        entries.insert(entry, at: insertionIndex(for: seq))
    }

    private static func role(_ role: String, card: PromptCard?) -> ChatEntry.Role {
        if card != nil { return .prompt }
        switch role {
        case "user": return .user
        case "system": return .system
        default: return .agent
        }
    }

    /// A card's status as the host reported it after an answer (before its update arrives).
    public mutating func setCardStatus(cardId: String, status: String) {
        guard let index = entries.firstIndex(where: { $0.card?.id == cardId }),
              entries[index].card?.status != status else { return }
        entries[index].card?.status = status
    }

    /// Where a saved message goes: before the first saved message with a higher seq;
    /// otherwise at the end.
    private func insertionIndex(for seq: Int) -> Int {
        entries.firstIndex(where: { ($0.seq ?? Int.min) > seq }) ?? entries.count
    }

    /// A message that just got its seq moves into host order if it's out of place
    /// (e.g. sent while another agent's reply was already being saved).
    private mutating func settle(at index: Int) {
        guard let seq = entries[index].seq else { return }
        let entry = entries.remove(at: index)
        entries.insert(entry, at: insertionIndex(for: seq))
    }
}
