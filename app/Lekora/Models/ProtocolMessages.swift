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

    public init(profile_id: String, name: String, avatar: String) {
        self.profile_id = profile_id
        self.name = name
        self.avatar = avatar
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

    public init(seq: Int, role: String, text: String) {
        self.seq = seq
        self.role = role
        self.text = text
    }
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
