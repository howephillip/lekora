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
    public let client_version: String
    public let proto_version: Int

    public init(
        device_id: String,
        device_token: String,
        last_seq: Int = 0,
        client_version: String = "1.0.0",
        proto_version: Int = 1
    ) {
        self.device_id = device_id
        self.device_token = device_token
        self.last_seq = last_seq
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

    public init(
        status: String = "ok",
        current_seq: Int,
        instance_name: String,
        profiles: [ProfileData]
    ) {
        self.status = status
        self.current_seq = current_seq
        self.instance_name = instance_name
        self.profiles = profiles
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

    public init(seq: Int, role: String, text: String, draft_id: String? = nil) {
        self.seq = seq
        self.role = role
        self.text = text
        self.draft_id = draft_id
    }
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
