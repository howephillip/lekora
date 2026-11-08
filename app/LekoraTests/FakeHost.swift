import Foundation
import Network
@testable import Lekora

/// A tiny local WebSocket server that answers like the Lekora host plugin
/// (pair.request, hello, chat.send), for testing the app's connection flow.
final class FakeHost: @unchecked Sendable {
    let instanceId = "inst_test"
    let instanceName = "Test Host"
    let validPairingToken = "pair_ok"
    let acceptedDeviceToken = "tok_good"
    /// The agents (Hermes profiles) this host offers, in order.
    var profiles: [[String: String]] = [["profile_id": "assistant", "name": "Assistant", "avatar": "sparkles"]]
    /// Messages the host has stored, replayed after `hello` when newer than `last_seq`.
    var history: [(seq: Int, role: String, text: String, profile: String)] = [
        (1, "user", "Hello from earlier", "assistant"),
        (2, "assistant", "Hi! Welcome back.", "assistant"),
    ]

    private let listener: NWListener
    private let queue = DispatchQueue(label: "app.lekora.tests.fakehost")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var _received: [[String: Any]] = []
    private(set) var port: UInt16 = 0
    /// Set once the app's Forget Host revoked the device; later unpairs are rejected.
    var unpaired = false
    /// Makes the next profile.delete fail like a failed backup.
    var failNextDelete = false
    /// Set to stop answering profile.create (to test the phone's timeout and disconnect handling).
    var ignoreCreates = false

    /// Like the plugin's `profiles.changed`: every live connection hears about agent changes.
    func broadcastProfiles() {
        lock.lock(); let open = connections; lock.unlock()
        for connection in open where connection.state == .ready {
            send(type: "profiles.changed", data: ["profiles": profiles], on: connection)
        }
    }

    var endpoint: String { "ws://127.0.0.1:\(port)" }

    /// Every envelope the app sent, in order.
    var received: [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return _received
    }

    func received(type: String) -> [[String: Any]] {
        received.filter { $0["type"] as? String == type }
    }

    init() throws {
        let parameters = NWParameters.tcp
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true  // the app's route probe is a WebSocket ping
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        listener = try NWListener(using: parameters, on: .any)
    }

    func start() async throws {
        port = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            let once = OnceFlag()
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    if once.claim() { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        lock.lock()
        let open = connections
        connections.removeAll()
        lock.unlock()
        open.forEach { $0.cancel() }
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        lock.lock(); connections.append(connection); lock.unlock()
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil else { return }
            if let data, !data.isEmpty,
               let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                self.lock.lock(); self._received.append(json); self.lock.unlock()
                self.respond(to: json, on: connection)
            }
            self.receive(on: connection)
        }
    }

    private func respond(to message: [String: Any], on connection: NWConnection) {
        let id = message["id"] as? String
        let data = message["data"] as? [String: Any] ?? [:]

        switch message["type"] as? String {
        case "pair.request":
            guard data["pairing_token"] as? String == validPairingToken else {
                send(error: "TOKEN_INVALID", reason: "Pairing code is invalid or already used", id: id, on: connection, close: true)
                return
            }
            send(type: "pair.response", id: id, data: [
                "status": "ok", "proto_version": 1,
                "device_id": "dev_1", "device_token": acceptedDeviceToken,
                "instance_name": instanceName, "endpoints": [endpoint],
            ], on: connection)

        case "hello":
            guard data["device_token"] as? String == acceptedDeviceToken else {
                send(error: "AUTH_FAILED", reason: "Invalid or revoked device token", id: id, on: connection, close: true)
                return
            }
            let lastSeq = data["last_seq"] as? Int ?? 0
            send(type: "hello.ack", id: id, data: [
                "status": "ok", "current_seq": history.last?.seq ?? 0, "instance_name": instanceName,
                "profiles": profiles,
            ], on: connection)
            for event in history where event.seq > lastSeq {
                send(type: "chat.message", data: ["seq": event.seq, "role": event.role, "text": event.text],
                     profileId: event.profile, on: connection)
            }

        case "device.unpair":
            guard data["device_token"] as? String == acceptedDeviceToken, !unpaired else {
                send(error: "AUTH_FAILED", reason: "Invalid or revoked device token", id: id, on: connection, close: true)
                return
            }
            unpaired = true
            send(type: "device.unpair.ack", id: id,
                 data: ["status": "ok", "device_id": data["device_id"] as? String ?? ""], on: connection)
            queue.asyncAfter(deadline: .now() + 0.1) { connection.cancel() }

        case "profile.create":
            if ignoreCreates { return }
            let name = data["name"] as? String ?? ""
            let profileId = ProfileNaming.id(for: name)
            guard !profileId.isEmpty else {
                send(error: "INVALID_NAME", reason: "Give the agent a name", id: id, on: connection, close: false)
                return
            }
            guard !profiles.contains(where: { $0["profile_id"] == profileId }) else {
                send(error: "PROFILE_EXISTS", reason: "An agent called '\(profileId)' already exists", id: id, on: connection, close: false)
                return
            }
            var created = ["profile_id": profileId, "name": profileId.capitalized, "avatar": "sparkles"]
            if let description = data["description"] as? String { created["description"] = description }
            profiles.append(created)
            send(type: "profile.create.ack", id: id, data: ["status": "ok", "profile": created], on: connection)
            broadcastProfiles()

        case "profile.delete":
            let profileId = data["profile_id"] as? String ?? ""
            if profileId == "default" {
                send(error: "CANNOT_DELETE_DEFAULT", reason: "The default agent can't be deleted", id: id, on: connection, close: false)
            } else if data["confirm"] as? String != profileId {
                send(error: "CONFIRMATION_REQUIRED", reason: "Deleting an agent needs explicit confirmation", id: id, on: connection, close: false)
            } else if !profiles.contains(where: { $0["profile_id"] == profileId }) {
                send(error: "UNKNOWN_PROFILE", reason: "There is no agent called '\(profileId)'", id: id, on: connection, close: false)
            } else if failNextDelete {
                failNextDelete = false
                send(error: "BACKUP_FAILED", reason: "Backup failed, so nothing was deleted", id: id, on: connection, close: false)
            } else {
                profiles.removeAll { $0["profile_id"] == profileId }
                history.removeAll { $0.profile == profileId }
                send(type: "profile.delete.ack", id: id,
                     data: ["status": "ok", "profile_id": profileId, "backup": "lekora-backups/profiles/\(profileId)-x.tar.gz"],
                     on: connection)
                broadcastProfiles()
            }

        case "chat.send":
            // Like the plugin: unknown agents are rejected; replies come from the agent addressed.
            let profile = message["profile_id"] as? String ?? ""
            guard profiles.contains(where: { $0["profile_id"] == profile }) else {
                send(error: "UNKNOWN_PROFILE", reason: "Unknown profile", id: id, on: connection, close: false)
                return
            }
            let text = data["text"] as? String ?? ""
            let reply = "\(profile) says: \(text)"
            let seq = (history.last?.seq ?? 0) + 1
            history.append((seq, "user", text, profile))
            history.append((seq + 1, "assistant", reply, profile))
            send(type: "chat.message", data: ["seq": seq + 1, "role": "assistant", "text": reply],
                 profileId: profile, on: connection)

        default:
            break
        }
    }

    private func send(type: String, id: String? = nil, data: [String: Any], profileId: String? = nil, on connection: NWConnection) {
        var envelope: [String: Any] = [
            "v": 1, "id": id ?? UUID().uuidString, "type": type,
            "instance_id": instanceId, "ts": "2026-11-07T21:05:00Z", "data": data,
        ]
        if let profileId { envelope["profile_id"] = profileId }
        guard let body = try? JSONSerialization.data(withJSONObject: envelope) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "message", metadata: [metadata])
        connection.send(content: body, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    private func send(error code: String, reason: String, id: String?, on connection: NWConnection, close: Bool) {
        send(type: "error", id: id, data: ["code": code, "reason": reason, "recoverable": false], on: connection)
        if close {
            queue.asyncAfter(deadline: .now() + 0.1) { connection.cancel() }
        }
    }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

/// Keychain stand-in for tests.
final class InMemoryCredentialStore: CredentialStore {
    private(set) var values: [String: String] = [:]

    func save(key: String, value: String) throws { values[key] = value }
    func get(key: String) throws -> String? { values[key] }
    func delete(key: String) throws { values[key] = nil }
}

@MainActor
func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}
