import Foundation
import AVFoundation
import LiveKit

// Live voice engines for calls (docs/live-calls.md; owner, 2026-11-22): a real-time voice model talks
// with you while your own agent does the real work.
// - GPT-Live: the microphone's sound goes to the Hermes instance (which holds the OpenAI key) and the
//   voice comes back the same way.
// - Fish Live 3: a LiveKit call with Lekora's Fish voice agent; its ask_agent tool calls come to the
//   phone, which asks the agent through the instance and answers with its reply.

@MainActor
public final class LiveCallSession: ObservableObject {
    @Published public private(set) var phase: HandsFreeSession.Phase = .starting { didSet { onChange?() } }
    @Published public var muted = false {
        didSet { onChange?(); Task { await applyMute() } }
    }
    @Published public private(set) var level: Double = 0 { didSet { onChange?() } }
    /// The call screen holds this call in a @State, which doesn't follow its changes: it's told here
    /// (owner, 2026-11-23: a connected Fish call still said "Starting…").
    var onChange: (() -> Void)?

    let gateway: GatewayClient
    let profileId: String
    let engine: String

    // GPT-Live
    private let microphone = HandsFreeMicrophone()
    private var detector = SpeechDetector()
    private var converter: AVAudioConverter?
    private let wire = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true)!
    private var pending = Data()
    private var working = false
    // Fish Live 3
    private var room: Room?
    private var roomEvents: FishRoomEvents?
    private var ended = false

    public init(gateway: GatewayClient, profileId: String, engine: String) {
        self.gateway = gateway
        self.profileId = profileId
        self.engine = engine
    }

    public func start() async {
        AudioSessionOwner.handsFree = true
        guard await AVAudioApplication.requestRecordPermission() else {
            phase = .failed("Lekora needs the microphone for calls. You can allow it in Settings › Lekora.")
            return
        }
        do {
            let started = try await gateway.startLive(engine, for: profileId)
            if engine == "fish-live" {
                try await startFish(url: started.livekit_url ?? "", token: started.token ?? "")
            } else {
                try startGpt()
            }
            gateway.reportVoiceLog("live call started: \(engine)", profileId: profileId)
        } catch {
            phase = .failed("\(engineName) couldn't start: \(error.localizedDescription)")
        }
    }

    private var engineName: String { engine == "fish-live" ? "Fish Live 3" : "GPT-Live" }

    public func end() {
        guard !ended else { return }
        ended = true
        gateway.onLiveAudio = nil
        gateway.onLiveEvent = nil
        microphone.stop()
        if let room {
            Task { await room.disconnect() }
        }
        room = nil
        AudioSessionOwner.handsFree = false
        let gateway = gateway, profileId = profileId
        Task { await gateway.stopLive(for: profileId) }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func applyMute() async {
        if let room {
            _ = try? await room.localParticipant.setMicrophone(enabled: !muted)
        } else {
            await gateway.muteLive(muted, for: profileId)
        }
    }

    // MARK: - GPT-Live, relayed through the instance

    private func startGpt() throws {
        gateway.onLiveAudio = { [weak self] base64 in self?.voiceArrived(base64) }
        gateway.onLiveEvent = { [weak self] event in self?.event(event) }
        microphone.onLevel = { [weak self] dB, duration in self?.heard(level: dB, duration: duration) }
        microphone.onBuffer = { [weak self] buffer in self?.captured(buffer) }
        microphone.speech.onIdle = { [weak self] in self?.idle() }
        try microphone.start()
        phase = .listening
    }

    /// The voice's sound, played as it arrives.
    private func voiceArrived(_ base64: String) {
        guard let pcm = Data(base64Encoded: base64), !pcm.isEmpty else { return }
        microphone.speech.play(pcm: pcm, rate: 24_000)
        microphone.speech.flush()
        phase = .speaking
    }

    private func idle() {
        if phase == .speaking { phase = working ? .thinking : .listening }
    }

    private func event(_ event: LiveEventData) {
        switch event.kind {
        case "working":
            working = true
            if phase != .speaking { phase = .thinking }
        case "done":
            working = false
            if phase == .thinking { phase = .listening }
        case "error":
            gateway.reportVoiceLog("live call error: \(event.text ?? "")", profileId: profileId)
        case "closed":
            if !ended { phase = .failed("The call ended (\(event.text ?? "closed")).") }
        default:
            break
        }
    }

    /// GPT-Live decides turn-taking itself but says nothing when you cut in, so the phone drops what's
    /// still queued of its voice the moment you start talking (louder than its echo: about -30 dB).
    private func heard(level dB: Float, duration: TimeInterval) {
        level = VoiceWaveform.level(fromDecibels: dB)
        guard !muted else { return }
        let talking = microphone.speech.isSpeaking
        let counted = talking && dB < -30 ? min(dB, detector.threshold - 1) : dB
        if detector.feed(level: counted, duration: duration) == .started, talking {
            microphone.speech.stop()
            phase = .hearing
        }
        if phase == .hearing, !detector.talking { phase = working ? .thinking : .listening }
    }

    /// The microphone's sound, as 16-bit 24 kHz mono, sent about every 100 ms.
    private func captured(_ buffer: AVAudioPCMBuffer) {
        guard !muted, !ended else { return }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: wire)
        }
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * wire.sampleRate / buffer.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: wire, frameCapacity: capacity) else { return }
        var given = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let samples = out.int16ChannelData?[0] else { return }
        pending.append(Data(bytes: samples, count: Int(out.frameLength) * 2))
        if pending.count >= 4_800 {  // 100 ms
            gateway.sendLiveAudio(pending.base64EncodedString(), profileId: profileId)
            pending.removeAll(keepingCapacity: true)
        }
    }

    // MARK: - Fish Live 3, over LiveKit

    private func startFish(url: String, token: String) async throws {
        guard !url.isEmpty, !token.isEmpty else { throw McpFailure(reason: "Fish didn't give a call pass") }
        let events = FishRoomEvents()
        events.onToolCall = { [weak self] callId, request in self?.answerTool(callId: callId, request: request) }
        events.onAgentState = { [weak self] state in self?.agentState(state) }
        events.onEnded = { [weak self] reason in
            guard let self, !self.ended else { return }
            self.phase = .failed("The call ended (\(reason)).")
        }
        let room = Room(delegate: events)
        self.room = room
        self.roomEvents = events
        try await room.connect(url: url, token: token)
        try await room.localParticipant.setMicrophone(enabled: true)
        phase = .listening
    }

    private func agentState(_ state: String) {
        switch state {
        case "speaking": phase = .speaking
        case "thinking": phase = .thinking
        case "listening", "idle": phase = .listening
        default: break
        }
    }

    /// Fish asked the agent something: the instance asks it as a chat turn; its reply is the tool's result.
    private func answerTool(callId: String, request: String) {
        phase = .thinking
        Task {
            var result: [String: Any] = ["type": "client_tool.result", "callId": callId]
            do {
                let answer = try await gateway.askAgentLive(request, for: profileId)
                result["result"] = ["answer": answer]
            } catch {
                result["result"] = ["error": error.localizedDescription]
                result["isError"] = true
            }
            guard let room, let data = try? JSONSerialization.data(withJSONObject: result) else { return }
            try? await room.localParticipant.publish(data: data, options: DataPublishOptions(topic: "client-event", reliable: true))
        }
    }
}

/// LiveKit's room events for a Fish call (its protocol: tool calls on `agent-event`, the agent's state
/// as the `lk.agent.state` attribute).
final class FishRoomEvents: NSObject, RoomDelegate, @unchecked Sendable {
    var onToolCall: (@MainActor (String, String) -> Void)?
    var onAgentState: (@MainActor (String) -> Void)?
    var onEnded: (@MainActor (String) -> Void)?

    func room(_ room: Room, participant: RemoteParticipant?, didReceiveData data: Data, forTopic topic: String,
              encryptionType: EncryptionType) {
        guard topic == "agent-event", let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        switch event["type"] as? String {
        case "client_tool.call":
            guard let callId = event["callId"] as? String else { return }
            let params = event["params"] as? [String: Any]
            let request = params?["request"] as? String ?? ""
            Task { @MainActor in self.onToolCall?(callId, request) }
        case "session.ended":
            let reason = event["reason"] as? String ?? "ended"
            Task { @MainActor in self.onEnded?(reason) }
        default:
            break
        }
    }

    func room(_ room: Room, participant: Participant, didUpdateAttributes attributes: [String: String]) {
        guard let state = participant.attributes["lk.agent.state"] else { return }
        Task { @MainActor in self.onAgentState?(state) }
    }
}
