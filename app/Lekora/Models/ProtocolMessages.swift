import Foundation

// MARK: - Generic Protocol Envelope
public struct Envelope<T: Codable>: Codable {
    public let v: Int
    public let id: String
    public let type: String
    public let instance_id: String
    public let profile_id: String?
    public let ts: String
    public let data: T

    public init(
        v: Int = 1,
        id: String = UUID().uuidString,
        type: String,
        instance_id: String,
        profile_id: String? = nil,
        ts: String = ISO8601DateFormatter().string(from: Date()),
        data: T
    ) {
        self.v = v
        self.id = id
        self.type = type
        self.instance_id = instance_id
        self.profile_id = profile_id
        self.ts = ts
        self.data = data
    }
}

/// Just enough of an envelope to decide how to decode the rest.
public struct EnvelopeHeader: Codable {
    public let type: String
    public let id: String
    public let profile_id: String?
}

// MARK: - Pairing Payloads
public struct PairRequestData: Codable, Equatable {
    public let pairing_token: String
    public let device_name: String
    public let client_version: String
    public let supported_proto_versions: [Int]

    public init(
        pairing_token: String,
        device_name: String,
        client_version: String = "1.0.0",
        supported_proto_versions: [Int] = [1]
    ) {
        self.pairing_token = pairing_token
        self.device_name = device_name
        self.client_version = client_version
        self.supported_proto_versions = supported_proto_versions
    }
}

public struct PairResponseData: Codable, Equatable {
    public let status: String
    public let proto_version: Int
    public let device_id: String
    public let device_token: String
    public let instance_name: String
    public let endpoints: [String]

    public init(
        status: String = "ok",
        proto_version: Int = 1,
        device_id: String,
        device_token: String,
        instance_name: String,
        endpoints: [String]
    ) {
        self.status = status
        self.proto_version = proto_version
        self.device_id = device_id
        self.device_token = device_token
        self.instance_name = instance_name
        self.endpoints = endpoints
    }
}

// MARK: - Session Handshake Payloads
public struct HelloData: Codable, Equatable {
    public let device_id: String
    public let device_token: String
    public let last_seq: Int
    /// Highest change number this phone has (0 = no cache); the host replays changes since
    /// it (docs/chat-history.md). Absent from apps before chat history.
    public let since_rev: Int?
    public let client_version: String
    public let proto_version: Int

    public init(
        device_id: String,
        device_token: String,
        last_seq: Int = 0,
        since_rev: Int? = nil,
        client_version: String = "1.0.0",
        proto_version: Int = 1
    ) {
        self.device_id = device_id
        self.device_token = device_token
        self.last_seq = last_seq
        self.since_rev = since_rev
        self.client_version = client_version
        self.proto_version = proto_version
    }
}

public struct ProfileData: Codable, Identifiable, Equatable {
    public var id: String { profile_id }
    public let profile_id: String
    public let name: String
    public let avatar: String
    /// What this agent is for, from the Hermes profile's `profile.yaml` (optional).
    public let description: String?

    public init(profile_id: String, name: String, avatar: String, description: String? = nil) {
        self.profile_id = profile_id
        self.name = name
        self.avatar = avatar
        self.description = description
    }
}

public struct HelloAckData: Codable, Equatable {
    public let status: String
    public let current_seq: Int
    public let instance_name: String
    public let profiles: [ProfileData]
    /// The host's current change number (hosts with chat history).
    public let rev: Int?
    /// "changes" (only what changed since `since_rev` follows) or "recent" (each agent's
    /// newest messages follow; drop cached ones). Absent from older hosts.
    public let replay: String?
    /// Each agent's read marker: highest seq read on any of the user's phones.
    public let read: [String: Int]?
    /// True when messages carry the time they were saved (`at`).
    public let message_times: Bool?

    public init(
        status: String = "ok",
        current_seq: Int,
        instance_name: String,
        profiles: [ProfileData],
        rev: Int? = nil,
        replay: String? = nil,
        read: [String: Int]? = nil,
        message_times: Bool? = nil
    ) {
        self.status = status
        self.current_seq = current_seq
        self.instance_name = instance_name
        self.profiles = profiles
        self.rev = rev
        self.replay = replay
        self.read = read
        self.message_times = message_times
    }
}

// MARK: - Walking Skeleton Chat Payloads
public struct ChatSendData: Codable, Equatable {
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

public struct ChatMessageData: Codable, Equatable {
    public let seq: Int
    public let role: String
    public let text: String
    /// Set when this saved message replaces a live reply (`chat.draft`) on the phone.
    public let draft_id: String?
    /// Change number: new when saved, new again when corrected (docs/chat-history.md).
    public let rev: Int?
    /// On user messages: the `chat.send` id, so the sending phone matches its own bubble.
    public let client_id: String?
    /// When the host saved it, UTC ISO 8601 (docs/agents-home.md).
    public let at: String?
    /// An approval or question card (docs/prompts.md).
    public let card: PromptCard?

    public init(seq: Int, role: String, text: String, draft_id: String? = nil,
                rev: Int? = nil, client_id: String? = nil, at: String? = nil, card: PromptCard? = nil) {
        self.seq = seq
        self.role = role
        self.text = text
        self.draft_id = draft_id
        self.rev = rev
        self.client_id = client_id
        self.at = at
        self.card = card
    }

    /// `at` as a date (nil if absent or unreadable).
    public var date: Date? {
        at.flatMap { try? Date($0, strategy: .iso8601) }
    }
}

// MARK: - Approval and question cards (docs/prompts.md)
/// An agent asking for permission to do something risky, or asking you a question.
public struct PromptCard: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case approval, question }

    public let kind: Kind
    public let id: String
    public var status: String
    // Approval
    public let command: String?
    public let description: String?
    public let smartDenied: Bool?
    public let expiresAt: String?
    public var reason: String?
    // Question
    public let question: String?
    public let multiSelect: Bool?
    public var answer: String?
    /// Approval: the choices Hermes allows (once / session / always / deny). Question: its options.
    public let choices: [String]

    enum CodingKeys: String, CodingKey {
        case kind, id, status, command, description, reason, question, answer, choices
        case smartDenied = "smart_denied", expiresAt = "expires_at", multiSelect = "multi_select"
    }

    public init(kind: Kind, id: String, status: String = "pending", command: String? = nil,
                description: String? = nil, smartDenied: Bool? = nil, expiresAt: String? = nil,
                reason: String? = nil, question: String? = nil, multiSelect: Bool? = nil,
                answer: String? = nil, choices: [String] = []) {
        self.kind = kind
        self.id = id
        self.status = status
        self.command = command
        self.description = description
        self.smartDenied = smartDenied
        self.expiresAt = expiresAt
        self.reason = reason
        self.question = question
        self.multiSelect = multiSelect
        self.answer = answer
        self.choices = choices
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        id = try c.decode(String.self, forKey: .id)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "pending"
        command = try c.decodeIfPresent(String.self, forKey: .command)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        smartDenied = try c.decodeIfPresent(Bool.self, forKey: .smartDenied)
        expiresAt = try c.decodeIfPresent(String.self, forKey: .expiresAt)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        question = try c.decodeIfPresent(String.self, forKey: .question)
        multiSelect = try c.decodeIfPresent(Bool.self, forKey: .multiSelect)
        answer = try c.decodeIfPresent(String.self, forKey: .answer)
        choices = try c.decodeIfPresent([String].self, forKey: .choices) ?? []
    }

    public var isPending: Bool { status == "pending" }

    /// When Hermes stops waiting (approvals).
    public var expiryDate: Date? { expiresAt.flatMap { try? Date($0, strategy: .iso8601) } }

    /// Pending and not past its deadline.
    public func isOpen(now: Date = Date()) -> Bool {
        guard isPending else { return false }
        if let expiry = expiryDate, expiry <= now { return false }
        return true
    }
}

public struct PromptRespondData: Codable, Equatable {
    public let card_id: String
    public let choice: String?
    public let reason: String?
    public let answers: [String]?
    public let text: String?

    public init(card_id: String, choice: String? = nil, reason: String? = nil,
                answers: [String]? = nil, text: String? = nil) {
        self.card_id = card_id
        self.choice = choice
        self.reason = reason
        self.answers = answers
        self.text = text
    }
}

public struct PromptRespondAckData: Codable, Equatable {
    public let card_id: String
    public let status: String
}

// MARK: - Chat history and read state (docs/chat-history.md)
/// A page of one agent's messages older than `before_seq` (all, when nil).
public struct HistoryFetchData: Codable, Equatable {
    public let before_seq: Int?
    public let limit: Int
}

public struct HistoryPageData: Codable, Equatable {
    public let messages: [ChatMessageData]
    public let has_more: Bool
}

/// Both directions: "read up to `seq`" for the envelope's agent.
public struct ChatReadData: Codable, Equatable {
    public let seq: Int
}

// MARK: - Streaming (docs/streaming.md); neither is stored or replayed by the host
/// A reply being written: the full text so far. Empty text = drop the live bubble.
public struct ChatDraftData: Codable, Equatable {
    public let draft_id: String
    public let text: String
}

/// Whether an agent is working, and on what ("Searching the web…") when Hermes knows.
public struct ChatTypingData: Codable, Equatable {
    public let active: Bool
    public let status: String?
}

// MARK: - Unpairing ("Forget Host")
/// Sent on a fresh socket without `hello`: carries its own credentials.
public struct DeviceUnpairData: Codable, Equatable {
    public let device_id: String
    public let device_token: String

    public init(device_id: String, device_token: String) {
        self.device_id = device_id
        self.device_token = device_token
    }
}

public struct DeviceUnpairAckData: Codable, Equatable {
    public let status: String
    public let device_id: String
}

// MARK: - Standard Error Envelope Payload
public struct ErrorData: Codable, Equatable {
    public let code: String
    public let reason: String
    public let recoverable: Bool?

    public init(code: String, reason: String, recoverable: Bool? = nil) {
        self.code = code
        self.reason = reason
        self.recoverable = recoverable
    }
}

// MARK: - Agent lifecycle (docs/agent-lifecycle.md)
public struct ProfileCreateData: Codable, Equatable {
    public let name: String
    public let description: String?
}

public struct ProfileCreateAckData: Codable, Equatable {
    public let status: String
    public let profile: ProfileData
}

/// `confirm` must equal `profile_id`: the host refuses a delete without it.
public struct ProfileDeleteData: Codable, Equatable {
    public let profile_id: String
    public let confirm: String
}

public struct ProfileDeleteAckData: Codable, Equatable {
    public let status: String
    public let profile_id: String
    /// Where the host saved the backup, relative to the Hermes folder.
    public let backup: String
}

/// Broadcast to every phone when agents are created or deleted.
public struct ProfilesChangedData: Codable, Equatable {
    public let profiles: [ProfileData]
}

/// Mirrors the host's rule ('Research Assistant' -> 'research-assistant'), so the phone can
/// show the id an agent will get. The host decides.
public enum ProfileNaming {
    public static func id(for name: String) -> String {
        var slug = ""
        var pendingDash = false
        for scalar in name.lowercased().unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                if pendingDash && !slug.isEmpty { slug.append("-") }
                slug.unicodeScalars.append(scalar)
                pendingDash = false
            } else {
                pendingDash = true
            }
        }
        var trimmed = String(slug.prefix(64))
        while trimmed.hasSuffix("-") { trimmed.removeLast() }
        return trimmed
    }
}
