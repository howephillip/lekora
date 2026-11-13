import Foundation
import Network
@testable import Lekora

/// A tiny local WebSocket server that answers like the Lekora host plugin
/// (pair.request, hello, chat.send), for testing the app's connection flow.
final class FakeHost: @unchecked Sendable {
    let instanceId: String
    /// The computer's name; `instance.rename` changes it (docs/multiple-instances.md).
    var instanceName: String
    /// What the agents call the user (docs/your-name.md); nil acts like an older plugin.
    var userName: String? = ""
    /// Sends everything as if from this other computer (to check the app ignores it).
    var pretendInstanceId: String?
    let validPairingToken = "pair_ok"
    let acceptedDeviceToken = "tok_good"
    /// The agents (Hermes profiles) this host offers, in order.
    var profiles: [[String: String]] = [["profile_id": "assistant", "name": "Assistant", "avatar": "sparkles"]]
    /// Messages the host has stored, replayed after `hello` when newer than `last_seq`.
    var history: [(seq: Int, role: String, text: String, profile: String)] = [
        (1, "user", "Hello from earlier", "assistant"),
        (2, "assistant", "Hi! Welcome back.", "assistant"),
    ]

    /// Chat history (docs/chat-history.md). A message's change number is 10 × its seq until
    /// corrected; a correction takes the next number.
    var corrections: [Int: Int] = [:]
    /// Read markers per agent, as the plugin keeps them.
    var readMarkers: [String: Int] = [:]
    /// Each agent's newest N messages for a phone with no cache ("recent" replay).
    var recentLimit = 50
    /// Answer `hello` like a host from before chat history (no rev / replay / read).
    var legacyHello = false
    /// Every message carries this `at` time, like current hosts; nil = a host from before times.
    var messageTime: String? = "2026-11-08T12:00:00Z"

    /// The routing saved by models.routing.set (docs/model-picker.md).
    var routing: [String: Any] = ["mode": "balanced", "hosts": []]

    /// Hearing replies (docs/voice.md §2).
    var voiceSettings: [String: Any] = ["speak": "off", "engine": "iphone", "rate": 0.5]
    var hermesVoiceAvailable = true

    /// An agent's tools in Lekora chats (docs/agent-tools.md).
    var enabledTools: Set<String> = ["web", "file"]

    func toolsData() -> [String: Any] {
        ["toolsets": ["web", "file", "kanban"].map { ["key": $0, "label": $0.capitalized, "description": "", "enabled": enabledTools.contains($0)] },
         "elsewhere": ["telegram": ["file", "kanban", "web"]]]
    }

    /// Voice mode: a reply is being made into a voice note (or why its audio can't play).
    func sendVoiceReply(messageId: String, style: String, problem: String? = nil, profile: String) {
        var data: [String: Any] = ["message_id": messageId, "style": style]
        if let problem { data["problem"] = problem }
        lock.lock(); let open = connections.filter { $0.state == .ready }; lock.unlock()
        for connection in open { send(type: "voice.reply", data: data, profileId: profile, on: connection) }
    }

    /// Direct voice (docs/voice.md §4).
    var directVoice: [String: Any] = [
        "source": "auto",
        "fish": ["voice_id": "", "model": "s2.1-pro", "speed": 1.0],
        "elevenlabs": ["voice_id": "", "model_id": "eleven_flash_v2_5"],
        "openai": ["base_url": "https://api.openai.com/v1", "model": "gpt-4o-mini-tts", "voice": "alloy"],
    ]
    var directKeys: [String: String] = ["fish": "FISH_API_KEY", "elevenlabs": "", "openai": ""]

    func sendVoiceStream(messageId: String, index: Int, chunk: Int, pcm: Data, profile: String, streamingReply: Bool = true) {
        lock.lock(); let open = connections.filter { $0.state == .ready }; lock.unlock()
        for connection in open {
            if streamingReply, chunk == 0, index == 0 {
                send(type: "voice.reply", data: ["message_id": messageId, "style": "tts", "streaming": true],
                     profileId: profile, on: connection)
            }
            send(type: "voice.stream", data: ["message_id": messageId, "index": index, "chunk": chunk, "rate": 24000,
                                              "data": pcm.base64EncodedString()], profileId: profile, on: connection)
        }
    }

    /// Voice mode: a spoken part of a reply, as the plugin streams it.
    func sendVoiceSegment(messageId: String, index: Int, file: [String: Any], profile: String, inline: Data? = nil) {
        var data: [String: Any] = ["message_id": messageId, "index": index, "file": file]
        if let inline { data["data"] = inline.base64EncodedString() }
        lock.lock(); let open = connections.filter { $0.state == .ready }; lock.unlock()
        for connection in open {
            send(type: "voice.segment", data: data, profileId: profile, on: connection)
        }
    }

    /// The voice settings changed on another phone.
    func changeVoiceElsewhere(_ settings: [String: Any], profile: String) {
        voiceSettings = settings
        lock.lock(); let open = connections.filter { $0.state == .ready }; lock.unlock()
        for connection in open {
            send(type: "voice.settings.changed", data: ["settings": settings], profileId: profile, on: connection)
        }
    }

    /// Files (docs/files.md): what was uploaded, by id; pieces of this size.
    var storedFiles: [String: (meta: [String: Any], data: Data)] = [:]
    var fileChunk = 4
    var failUploads = false
    /// The file ids each chat.send carried.
    var sentFiles: [[String]] = []

    /// Adds a file as if the agent had sent it.
    func storeFile(_ data: Data, name: String, mime: String) -> [String: Any] {
        let fileId = "f_\(storedFiles.count + 1)"
        let kind = ["image", "video", "audio"].first { mime.hasPrefix($0 + "/") } ?? "document"
        let meta: [String: Any] = ["file_id": fileId, "name": name, "mime": mime, "size": data.count, "kind": kind]
        storedFiles[fileId] = (meta, data)
        return meta
    }

    /// What settings.get answers (docs/chat-settings.md); settings.set changes it like Hermes would.
    var chatSettings: [String: Any] = [
        "model": ["model": "anthropic/claude-opus-5-5", "provider": "openrouter", "this_chat": false],
        "reasoning": ["effort": "medium", "this_chat": false], "show_reasoning": false, "fast": "normal",
        "yolo": false, "approvals": "manual", "title": "Ramen plans",
        "personality": ["current": "none", "options": [["name": "pirate", "description": "Talk like a pirate"]]],
        "usage": ["context_tokens": 50000, "context_length": 200000, "cost_usd": 0.42],
    ]

    /// What commands.list answers (docs/slash-commands.md).
    var slashCommands: [[String: Any]] = [
        ["name": "new", "description": "Start a new session", "args": "", "choices": [], "aliases": ["reset"],
         "group": "hermes", "category": "Session"],
        ["name": "approvals", "description": "Approval mode", "args": "[manual|smart|off]",
         "choices": ["manual", "smart", "off"], "aliases": [], "group": "hermes", "category": "Configuration"],
    ]

    /// Cards by seq (docs/prompts.md), and every prompt.respond received.
    var cards: [Int: [String: Any]] = [:]
    /// What the fake Hermes says about an answered card: nil = accept it.
    var respondStatusOverride: String?

    func rev(of seq: Int) -> Int { corrections[seq] ?? seq * 10 }

    /// The agent says something now.
    @discardableResult
    func say(profile: String, text: String) -> Int {
        let seq = (history.last?.seq ?? 0) + 1
        history.append((seq, "assistant", text, profile))
        broadcast(seq: seq)
        return seq
    }

    /// An agent asks for permission (an approval card) or asks a question.
    @discardableResult
    func ask(profile: String, card: [String: Any], role: String, text: String) -> Int {
        let seq = (history.last?.seq ?? 0) + 1
        history.append((seq, role, text, profile))
        cards[seq] = card
        broadcast(seq: seq)
        return seq
    }

    private func broadcast(seq: Int) {
        guard let event = history.first(where: { $0.seq == seq }) else { return }
        lock.lock(); let open = connections.filter { $0.state == .ready }; lock.unlock()
        for connection in open {
            send(type: "chat.message", data: messageData(event), profileId: event.profile, on: connection)
        }
    }

    /// The card changes state (answered elsewhere, timed out…).
    func updateCard(seq: Int, _ changes: [String: Any]) {
        guard var card = cards[seq] else { return }
        for (key, value) in changes { card[key] = value }
        cards[seq] = card
        corrections[seq] = currentRev + 1
        broadcast(seq: seq)
    }
    var currentRev: Int { history.map { rev(of: $0.seq) }.max() ?? 0 }

    private func messageData(_ event: (seq: Int, role: String, text: String, profile: String)) -> [String: Any] {
        var data: [String: Any] = ["seq": event.seq, "role": event.role, "text": event.text, "rev": rev(of: event.seq)]
        if let card = cards[event.seq] { data["card"] = card }
        if let files = messageFiles[event.seq] { data["files"] = files }
        if let voice = messageVoice[event.seq] { data["voice"] = voice }
        if let transcript = transcripts[event.seq] { data["transcript"] = transcript }
        if let messageTime { data["at"] = messageTime }
        return data
    }

    /// Voice notes (docs/voice.md): details by seq, every voice chat.send, transcripts by seq.
    var messageVoice: [Int: [String: Any]] = [:]
    var sentVoice: [[String: Any]] = []
    var transcripts: [Int: String] = [:]

    /// Hermes transcribed the voice note `seq`: resent with its transcript and a new rev.
    func transcribe(seq: Int, _ text: String) {
        transcripts[seq] = text
        corrections[seq] = currentRev + 1
        broadcast(seq: seq)
    }

    /// Files on saved messages, by seq.
    var messageFiles: [Int: [[String: Any]]] = [:]

    /// The agent sends files now.
    func sendFiles(profile: String, files: [[String: Any]], text: String = "") {
        let seq = (history.last?.seq ?? 0) + 1
        history.append((seq, "assistant", text, profile))
        messageFiles[seq] = files
        broadcast(seq: seq)
    }

    /// An agent corrects a saved message (e.g. while the phone is away).
    func correct(seq: Int, text: String) {
        guard let index = history.firstIndex(where: { $0.seq == seq }) else { return }
        let newRev = currentRev + 1
        history[index].text = text
        corrections[seq] = newRev
        lock.lock(); let open = connections.filter { $0.state == .ready }; lock.unlock()
        for connection in open {
            send(type: "chat.message", data: messageData(history[index]), profileId: history[index].profile, on: connection)
        }
    }

    /// Another phone read an agent's chat.
    func readElsewhere(profile: String, seq: Int) {
        readMarkers[profile] = seq
        lock.lock(); let open = connections.filter { $0.state == .ready }; lock.unlock()
        for connection in open {
            send(type: "chat.read", data: ["seq": seq], profileId: profile, on: connection)
        }
    }

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

    /// Streams a reply like the plugin does: typing, growing drafts, then the saved message
    /// linked to the draft. `seal: false` leaves it as a draft (a turn that ends unsealed).
    func streamReply(profile: String, words: [String], status: String? = nil, seal: Bool = true,
                     draftId: String = "live-test") {
        lock.lock(); let open = connections.filter { $0.state == .ready }; lock.unlock()
        var typing: [String: Any] = ["active": true]
        if let status { typing["status"] = status }
        var text = ""
        for connection in open {
            send(type: "chat.typing", data: typing, profileId: profile, on: connection)
        }
        for word in words {
            text = text.isEmpty ? word : text + " " + word
            for connection in open {
                send(type: "chat.draft", data: ["draft_id": draftId, "text": text], profileId: profile, on: connection)
            }
        }
        guard seal else { return }
        let seq = (history.last?.seq ?? 0) + 1
        history.append((seq, "assistant", text, profile))
        for connection in open {
            send(type: "chat.message", data: ["seq": seq, "role": "assistant", "text": text, "draft_id": draftId,
                                              "rev": rev(of: seq)],
                 profileId: profile, on: connection)
            send(type: "chat.typing", data: ["active": false], profileId: profile, on: connection)
        }
    }

    /// Like the plugin's `profiles.changed`: every live connection hears about agent changes.
    /// Renamed from another phone: tell every connected phone.
    func renameElsewhere(_ name: String) {
        instanceName = name
        lock.lock(); let open = connections.filter { $0.state == .ready }; lock.unlock()
        for connection in open { send(type: "instance.changed", data: ["instance_name": name], on: connection) }
    }

    func userNameElsewhere(_ name: String) {
        userName = name
        lock.lock(); let open = connections.filter { $0.state == .ready }; lock.unlock()
        for connection in open {
            send(type: "instance.changed", data: ["instance_name": instanceName, "user_name": name], on: connection)
        }
    }

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

    init(instanceId: String = "inst_test", instanceName: String = "Test Host") throws {
        self.instanceId = instanceId
        self.instanceName = instanceName
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
            var ack: [String: Any] = [
                "status": "ok", "current_seq": history.last?.seq ?? 0, "instance_name": instanceName,
                "profiles": profiles,
            ]
            if let userName { ack["user_name"] = userName }
            var replay = history.filter { $0.seq > lastSeq }
            if !legacyHello, let sinceRev = data["since_rev"] as? Int {
                if sinceRev > 0 {
                    ack["replay"] = "changes"
                    replay = history.filter { rev(of: $0.seq) > sinceRev }.sorted { rev(of: $0.seq) < rev(of: $1.seq) }
                } else {
                    ack["replay"] = "recent"
                    let ids = Set(history.map(\.profile))
                    let keep = Set(ids.flatMap { id in history.filter { $0.profile == id }.suffix(recentLimit).map(\.seq) })
                    replay = history.filter { keep.contains($0.seq) }
                }
                ack["rev"] = currentRev
                if messageTime != nil { ack["message_times"] = true }
                ack["read"] = Dictionary(uniqueKeysWithValues: profiles.compactMap { $0["profile_id"] }.map { ($0, readMarkers[$0] ?? 0) })
            }
            send(type: "hello.ack", id: id, data: ack, on: connection)
            for event in replay {
                send(type: "chat.message", data: legacyHello ? ["seq": event.seq, "role": event.role, "text": event.text] : messageData(event),
                     profileId: event.profile, on: connection)
            }

        case "history.fetch":
            let profile = message["profile_id"] as? String ?? ""
            let before = data["before_seq"] as? Int ?? Int.max
            let limit = data["limit"] as? Int ?? 100
            let older = history.filter { $0.profile == profile && $0.seq < before }
            let page = older.suffix(limit)
            send(type: "history.page", id: id, data: [
                "messages": page.map { messageData($0) }, "has_more": older.count > page.count,
            ], profileId: profile, on: connection)

        case "models.catalog":
            send(type: "models.catalog.result", id: id, data: [
                "provider": data["provider"] as? String ?? "", "complete": true,
                "models": [["id": "deepseek/v4", "name": "DeepSeek V4", "maker": "deepseek", "maker_name": "DeepSeek",
                            "created": 2, "context": 1048576, "input": 0.08, "output": 0.5, "free": false,
                            "reasoning": true, "vision": true],
                           ["id": "meta/llama:free", "name": "Llama", "maker": "meta", "maker_name": "Meta",
                            "created": 1, "context": 131072, "input": 0, "output": 0, "free": true]]],
                 profileId: message["profile_id"] as? String, on: connection)

        case "models.hosts":
            send(type: "models.hosts.result", id: id, data: [
                "model": data["model"] as? String ?? "",
                "hosts": [["name": "Wafer", "tag": "wafer/us", "input": 0.038, "output": 0.5, "quantization": "mxfp4", "uptime": 99.7]],
                "routing": routing], profileId: message["profile_id"] as? String, on: connection)

        case "models.routing.set":
            routing = ["mode": data["mode"] as? String ?? "", "hosts": data["hosts"] as? [String] ?? []]
            var reply = routing
            reply["backup"] = "/home/x/.hermes/lekora-backups/config/bruce/config.yaml.20261109-120000"
            send(type: "models.routing.set.result", id: id, data: reply,
                 profileId: message["profile_id"] as? String, on: connection)

        case "user.name.set":
            userName = data["name"] as? String ?? ""
            send(type: "user.name.set.result", id: id, data: ["user_name": userName ?? ""], on: connection)

        case "instance.rename":
            instanceName = data["name"] as? String ?? instanceName
            send(type: "instance.rename.result", id: id, data: ["instance_name": instanceName], on: connection)

        case "settings.get":
            send(type: "settings.get.result", id: id, data: chatSettings,
                 profileId: message["profile_id"] as? String, on: connection)

        case "settings.set":
            let key = data["key"] as? String ?? ""
            if key == "fast", let mode = data["value"] as? String, !["normal", "fast", "auto", "ultrafast"].contains(mode) {
                send(type: "error", id: id, data: ["code": "INVALID_SETTING", "reason": "Unknown fast mode"],
                     profileId: message["profile_id"] as? String, on: connection)
                break
            }
            if let value = data["value"], ["yolo", "fast", "approvals", "show_reasoning"].contains(key) {
                chatSettings[key] = value
            }
            send(type: "settings.set.result", id: id, data: ["key": key, "command": "/\(key)"],
                 profileId: message["profile_id"] as? String, on: connection)

        case "settings.action":
            let action = data["action"] as? String ?? ""
            send(type: "settings.action.result", id: id, data: ["action": action, "command": "/\(action)"],
                 profileId: message["profile_id"] as? String, on: connection)

        case "commands.list":
            send(type: "commands.list.result", id: id,
                 data: ["commands": slashCommands, "fingerprint": "f\(slashCommands.count)"],
                 profileId: message["profile_id"] as? String, on: connection)

        case "prompt.respond":
            let cardId = data["card_id"] as? String ?? ""
            guard let seq = cards.first(where: { $0.value["id"] as? String == cardId })?.key else {
                send(error: "UNKNOWN_CARD", reason: "No such card", id: id, on: connection, close: false)
                return
            }
            var status = cards[seq]?["status"] as? String ?? "pending"
            if status == "pending", let model = data["model"] as? String {
                // Model picker: an expensive model needs confirming first.
                if let warning = cards[seq]?["warn"] as? String, data["confirmed"] as? Bool != true {
                    send(type: "prompt.respond.ack", id: id,
                         data: ["card_id": cardId, "status": "needs_confirmation", "message": warning], on: connection)
                    return
                }
                status = "chosen"
                var chosen: [String: Any] = ["model": model, "provider": data["provider"] as? String ?? ""]
                if let scope = data["scope"] as? String { chosen["scope"] = scope }
                updateCard(seq: seq, ["status": status, "chosen": chosen])
            } else if status == "pending" {
                if let choice = data["choice"] as? String, cards[seq]?["kind"] as? String == "choice" {
                    status = "chosen"
                    let label = ((cards[seq]?["options"] as? [[String: Any]]) ?? [])
                        .first { $0["value"] as? String == choice }?["label"] as? String ?? choice
                    updateCard(seq: seq, ["status": status, "answer": label])
                } else if let choice = data["choice"] as? String {
                    let statuses = cards[seq]?["kind"] as? String == "confirm"
                        ? ["once": "confirmed_once", "always": "confirmed_always", "cancel": "cancelled"]
                        : ["once": "allowed_once", "session": "allowed_session", "always": "allowed_always", "deny": "denied"]
                    status = respondStatusOverride ?? statuses[choice] ?? "denied"
                    var changes: [String: Any] = ["status": status]
                    if let reason = data["reason"] as? String { changes["reason"] = reason }
                    updateCard(seq: seq, changes)
                } else {
                    status = respondStatusOverride ?? "answered"
                    let answer = (data["text"] as? String) ?? ((data["answers"] as? [String]) ?? []).joined(separator: ", ")
                    updateCard(seq: seq, ["status": status, "answer": answer])
                }
            }
            send(type: "prompt.respond.ack", id: id, data: ["card_id": cardId, "status": status], on: connection)

        case "chat.read":
            let profile = message["profile_id"] as? String ?? ""
            if let seq = data["seq"] as? Int, seq > readMarkers[profile] ?? 0 { readMarkers[profile] = seq }

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

        case "file.upload.begin":
            let size = data["size"] as? Int ?? 0
            guard size <= 100 * 1024 * 1024 else {
                send(error: "FILE_TOO_LARGE", reason: "Files can be up to 100 MB", id: id, on: connection, close: false)
                return
            }
            let fileId = "f_\(storedFiles.count + 1)"
            let name = data["name"] as? String ?? "file"
            let mime = data["mime"] as? String ?? "application/octet-stream"
            let kind = ["image", "video", "audio"].first { mime.hasPrefix($0 + "/") } ?? "document"
            storedFiles[fileId] = (["file_id": fileId, "name": name, "mime": mime, "size": size, "kind": kind], Data())
            send(type: "file.upload.begin.result", id: id, data: ["file_id": fileId, "chunk_size": fileChunk], on: connection)

        case "file.upload.chunk":
            let fileId = data["file_id"] as? String ?? ""
            if failUploads {
                send(error: "UNAVAILABLE", reason: "Disk full", id: id, on: connection, close: false)
                return
            }
            guard var stored = storedFiles[fileId], let piece = Data(base64Encoded: data["data"] as? String ?? "") else {
                send(error: "UNKNOWN_FILE", reason: "That upload isn't here", id: id, on: connection, close: false)
                return
            }
            stored.data.append(piece)
            storedFiles[fileId] = stored
            send(type: "file.upload.chunk.result", id: id, data: ["file_id": fileId, "received": stored.data.count], on: connection)

        case "file.upload.end":
            let fileId = data["file_id"] as? String ?? ""
            guard let stored = storedFiles[fileId] else { return }
            send(type: "file.upload.end.result", id: id, data: ["file": stored.meta], on: connection)

        case "file.read":
            let fileId = data["file_id"] as? String ?? ""
            let offset = data["offset"] as? Int ?? 0
            guard let stored = storedFiles[fileId] else {
                send(error: "UNKNOWN_FILE", reason: "That file isn't here", id: id, on: connection, close: false)
                return
            }
            let end = min(offset + fileChunk, stored.data.count)
            let piece = stored.data.subdata(in: offset..<end)
            send(type: "file.read.result", id: id, data: [
                "file_id": fileId, "offset": offset, "data": piece.base64EncodedString(),
                "size": stored.data.count, "done": end >= stored.data.count], on: connection)

        case "files.usage":
            send(type: "files.usage.result", id: id, data: [
                "bytes": storedFiles.values.reduce(0) { $0 + $1.data.count }, "count": storedFiles.count], on: connection)

        case "agent.tools.get":
            send(type: "agent.tools.get.result", id: id, data: toolsData(),
                 profileId: message["profile_id"] as? String, on: connection)

        case "agent.tools.set":
            for (key, on) in data["changes"] as? [String: Bool] ?? [:] {
                if on { enabledTools.insert(key) } else { enabledTools.remove(key) }
            }
            send(type: "agent.tools.set.result", id: id, data: toolsData(),
                 profileId: message["profile_id"] as? String, on: connection)

        case "voice.settings.get":
            send(type: "voice.settings.get.result", id: id,
                 data: ["settings": voiceSettings, "hermes_voice": ["available": hermesVoiceAvailable, "provider": "elevenlabs"]],
                 profileId: message["profile_id"] as? String, on: connection)

        case "voice.settings.set":
            voiceSettings = data["settings"] as? [String: Any] ?? voiceSettings
            send(type: "voice.settings.set.result", id: id, data: ["settings": voiceSettings],
                 profileId: message["profile_id"] as? String, on: connection)

        case "voice.direct.get", "voice.direct.set":
            if message["type"] as? String == "voice.direct.set" {
                directVoice = data["settings"] as? [String: Any] ?? directVoice
                if let key = data["key"] as? [String: Any], let provider = key["provider"] as? String {
                    directKeys[provider] = (key["value"] as? String ?? "").isEmpty ? "" : "app"
                }
            }
            send(type: (message["type"] as? String ?? "") + ".result", id: id,
                 data: ["settings": directVoice, "keys": directKeys, "hermes_streaming": NSNull()],
                 profileId: message["profile_id"] as? String, on: connection)

        case "voice.direct.test":
            let meta = storeFile(Data("RIFF sample".utf8), name: "Voice sample.wav", mime: "audio/wav")
            send(type: "voice.direct.test.result", id: id, data: ["file": meta],
                 profileId: message["profile_id"] as? String, on: connection)

        case "voice.speak":
            let seq = data["seq"] as? Int ?? 0
            let meta = storeFile(Data("ID3 speech \(seq)".utf8), name: "Reply \(seq).mp3", mime: "audio/mpeg")
            send(type: "voice.speak.result", id: id, data: ["seq": seq, "file": meta, "files": [meta]],
                 profileId: message["profile_id"] as? String, on: connection)

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
            // Like the plugin: the sender gets its own message back with its seq and client_id.
            var echo = messageData(history[history.count - 2])
            if let id { echo["client_id"] = id }
            if let ids = data["files"] as? [String] {
                echo["files"] = ids.compactMap { storedFiles[$0]?.meta }
                sentFiles.append(ids)
            }
            if let voice = data["voice"] as? [String: Any] {
                echo["voice"] = voice
                messageVoice[history[history.count - 2].seq] = voice
                sentVoice.append(voice)
            }
            send(type: "chat.message", data: echo, profileId: profile, on: connection)
            send(type: "chat.message", data: messageData(history[history.count - 1]),
                 profileId: profile, on: connection)

        default:
            break
        }
    }

    private func send(type: String, id: String? = nil, data: [String: Any], profileId: String? = nil, on connection: NWConnection) {
        var envelope: [String: Any] = [
            "v": 1, "id": id ?? UUID().uuidString, "type": type,
            "instance_id": pretendInstanceId ?? instanceId, "ts": "2026-11-07T21:05:00Z", "data": data,
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
