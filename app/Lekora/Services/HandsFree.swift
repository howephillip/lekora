import Foundation
import AVFoundation
import Combine
import Speech
import os

enum HandsFreeLog {
    static let log = Logger(subsystem: "com.lekora.app", category: "HandsFree")
}

/// Hands-free conversation (docs/voice.md §3): the app listens, notices when you stop talking,
/// sends what you said as a voice note, plays the reply, and listens again. You can talk over
/// the agent to interrupt it. Runs with the screen locked (background audio).

/// When someone is talking, from microphone levels (dB). Adapts to the room's background noise.
public struct SpeechDetector {
    public enum Event: Equatable {
        case started
        case ended
    }

    /// Talking: this far above the background noise (and at least `minimumLevel`).
    public var margin: Float = 12
    public var minimumLevel: Float = -48
    /// Sustained sound before it counts as talking (a cough or a click doesn't).
    public var startAfter: TimeInterval = 0.15
    /// Quiet after talking before your turn ends.
    public var endAfter: TimeInterval = 1.2
    /// Shorter than this isn't a turn.
    public var minimumTurn: TimeInterval = 0.5
    /// One turn at most (also stops a steady noise from counting as talking forever).
    public var maximumTurn: TimeInterval = 60

    public private(set) var talking = false
    public private(set) var noiseFloor: Float = -60
    private var loudFor: TimeInterval = 0
    private var quietFor: TimeInterval = 0
    private var turnLength: TimeInterval = 0
    private var measured = false

    public init() {}

    public var threshold: Float { max(noiseFloor + margin, minimumLevel) }

    /// One level reading covering `duration` seconds. Returns an event when talking starts or ends.
    public mutating func feed(level: Float, duration: TimeInterval) -> Event? {
        if !measured {
            noiseFloor = level  // the room as it is when listening starts
            measured = true
            return nil
        }
        // Background noise: followed down at once (when nobody's talking), up slowly always, so a
        // steady noise (a fan, a car) stops counting as talking within a few seconds.
        if !talking, level < noiseFloor {
            noiseFloor = level
        } else {
            // Slower while talking, so a long stretch of speech never becomes "background".
            noiseFloor += (level - noiseFloor) * Float(min(duration * (talking ? 0.02 : 0.15), 1))
        }
        let loud = level > threshold
        if !talking {
            loudFor = loud ? loudFor + duration : 0
            if loudFor >= startAfter {
                talking = true
                quietFor = 0
                turnLength = loudFor
                return .started
            }
            return nil
        }
        turnLength += duration
        quietFor = loud ? 0 : quietFor + duration
        if quietFor >= endAfter || turnLength >= maximumTurn {
            talking = false
            loudFor = 0
            let spoke = turnLength - quietFor
            return spoke >= minimumTurn ? .ended : nil
        }
        return nil
    }

    /// Start over (e.g. after the agent spoke).
    public mutating func reset() {
        talking = false
        loudFor = 0
        quietFor = 0
        turnLength = 0
    }
}

/// The microphone side: continuous listening with echo cancellation, recording each turn.
@MainActor
final class HandsFreeMicrophone {
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var fileURL: URL?
    private var levels: [Double] = []
    private var recordedFrames: AVAudioFramePosition = 0
    private var sampleRate: Double = 48_000
    /// The last moment of sound before talking was noticed, so the first word isn't cut.
    private var preRoll: [AVAudioPCMBuffer] = []
    private let preRollSeconds = 0.35

    /// Level (dB) and how much time it covers, for every buffer.
    var onLevel: ((Float, TimeInterval) -> Void)?
    /// Every buffer, for the on-device transcriber.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    func start() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat,
                                options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP])
        try session.setActive(true)
        #endif
        let input = engine.inputNode
        try? input.setVoiceProcessingEnabled(true)  // echo cancellation: it doesn't hear the agent
        let format = input.outputFormat(forBus: 0)
        sampleRate = format.sampleRate
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            let level = Self.decibels(buffer)
            let duration = Double(buffer.frameLength) / format.sampleRate
            Task { @MainActor in self?.handle(buffer, level: level, duration: duration) }
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        fileURL = nil
    }

    var isRunning: Bool { engine.isRunning }

    private func handle(_ buffer: AVAudioPCMBuffer, level: Float, duration: TimeInterval) {
        onBuffer?(buffer)
        if let file {
            try? file.write(from: buffer)
            recordedFrames += AVAudioFramePosition(buffer.frameLength)
            levels.append(VoiceWaveform.level(fromDecibels: level))
        } else {
            preRoll.append(buffer)
            var kept = preRoll.reduce(0.0) { $0 + Double($1.frameLength) / sampleRate }
            while kept > preRollSeconds, let first = preRoll.first {
                kept -= Double(first.frameLength) / sampleRate
                preRoll.removeFirst()
            }
        }
        onLevel?(level, duration)
    }

    /// Talking started: record from just before it.
    func beginTurn() {
        guard file == nil, let format = preRoll.first?.format ?? Optional(engine.inputNode.outputFormat(forBus: 0)) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Voice note \(Self.stamp()).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        guard let opened = try? AVAudioFile(forWriting: url, settings: settings, commonFormat: format.commonFormat,
                                            interleaved: format.isInterleaved) else { return }
        file = opened
        fileURL = url
        levels = []
        recordedFrames = 0
        for buffer in preRoll {
            try? opened.write(from: buffer)
            recordedFrames += AVAudioFramePosition(buffer.frameLength)
        }
        preRoll = []
    }

    /// Talking ended: the recording (closed), its length and waveform.
    func endTurn(trailingSilence: TimeInterval) -> (url: URL, duration: TimeInterval, waveform: [Double])? {
        guard file != nil, let url = fileURL else { return nil }
        file = nil  // closes it
        fileURL = nil
        let duration = max(Double(recordedFrames) / sampleRate - trailingSilence * 0.6, 0.3)
        return (url, duration, VoiceWaveform.bars(levels))
    }

    /// Throw away a turn that's being recorded (muted, ended).
    func dropTurn() {
        file = nil
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        fileURL = nil
    }

    nonisolated static func decibels(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return -100 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
        let rms = sqrt(sum / Float(buffer.frameLength))
        return 20 * log10(max(rms, 0.000_001))
    }

    private static func stamp() -> String {
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return format.string(from: Date())
    }
}

/// The iPhone's own speech recognition, on the device, while hands-free listens (owner,
/// 2026-11-12: sending the words the moment you stop talking is much faster than uploading a
/// recording for Hermes to transcribe). Falls back to voice notes when it isn't available.
@MainActor
final class LiveTranscriber {
    private var analyzer: SpeechAnalyzer?
    /// To the recognizer's audio format (AVAudioConverter: works on iOS 26 and later).
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<Void, Never>?
    /// Words heard, by where they start in the audio (seconds); later results replace earlier.
    private var pieces: [(start: Double, end: Double, text: String)] = []
    private var fedSeconds: Double = 0
    private var turnStart: Double = 0
    private(set) var ready = false

    /// Which recognizer is listening (for the log): "speech", "dictation", or nil.
    private(set) var kind: String?

    /// Sets up recognition for the iPhone's language (downloading it the first time): Apple's
    /// newest recognizer, or dictation on iPhones (and simulators) without it.
    func prepare() async -> Bool {
        if await prepareSpeech() { kind = "speech"; return true }
        if await prepareDictation() { kind = "dictation"; return true }
        return false
    }

    private func prepareSpeech() async -> Bool {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else { return false }
        let module = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        guard await start(module) else { return false }
        results = Task { [weak self] in
            do {
                for try await result in module.results {
                    self?.heard(start: result.range.start.seconds, end: result.range.end.seconds,
                                text: String(result.text.characters))
                }
            } catch {}
        }
        return true
    }

    private func prepareDictation() async -> Bool {
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale.current) else { return false }
        let module = DictationTranscriber(locale: locale, preset: .progressiveShortDictation)
        guard await start(module) else { return false }
        results = Task { [weak self] in
            do {
                for try await result in module.results {
                    self?.heard(start: result.range.start.seconds, end: result.range.end.seconds,
                                text: String(result.text.characters))
                }
            } catch {}
        }
        return true
    }

    private func start(_ module: any SpeechModule) async -> Bool {
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                try await request.downloadAndInstall()
            }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else { return false }
            let analyzer = SpeechAnalyzer(modules: [module])
            let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
            try await analyzer.start(inputSequence: stream)
            targetFormat = format
            self.analyzer = analyzer
            input = continuation
            ready = true
            return true
        } catch {
            HandsFreeLog.log.error("Speech recognition couldn't start: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard ready, let input, let target = targetFormat else { return }
        fedSeconds += Double(buffer.frameLength) / buffer.format.sampleRate
        if buffer.format == target {
            input.yield(AnalyzerInput(buffer: buffer))
            return
        }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
        }
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 1
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var given = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return buffer
        }
        if error == nil, out.frameLength > 0 { input.yield(AnalyzerInput(buffer: out)) }
    }

    private func heard(start: Double, end: Double, text: String) {
        // A newer reading of the same stretch of audio replaces the older one.
        pieces.removeAll { $0.start < end && $0.end > start }
        pieces.append((start, end, text))
        pieces.sort { $0.start < $1.start }
        if pieces.count > 400 { pieces.removeFirst(pieces.count - 400) }
    }

    /// Talking started (allowing for the moment before it was noticed).
    func beginTurn(lookBack: Double = 0.5) {
        turnStart = max(fedSeconds - lookBack, 0)
    }

    /// Words recognised so far in this turn (for interrupting the agent only on real speech).
    var wordsSoFar: String {
        pieces.filter { $0.end > turnStart }.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Talking ended: what was said in this turn, once recognition has caught up.
    func endTurn() async -> String {
        if let analyzer, let input {
            _ = input  // keep feeding: recognition goes on for the next turn
            try? await analyzer.finalize(through: CMTime(seconds: fedSeconds, preferredTimescale: 48_000))
        }
        let words = pieces.filter { $0.end > turnStart }.map(\.text).joined(separator: " ")
        return words.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    func stop() {
        input?.finish()
        results?.cancel()
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        ready = false
    }
}

/// One hands-free conversation with the chat's agent.
@MainActor
public final class HandsFreeSession: ObservableObject {
    public enum Phase: Equatable {
        case starting
        case listening
        case hearing          // you're talking
        case thinking         // sent; waiting for the reply
        case speaking         // the reply is playing
        case failed(String)
    }

    @Published public private(set) var phase: Phase = .starting
    @Published public var muted = false {
        didSet {
            if muted, phase == .hearing { microphone.dropTurn(); phase = .listening }
            detector.reset()
        }
    }
    /// 0…1, for the listening animation.
    @Published public private(set) var level: Double = 0
    /// What was last said, either way, for the caption.
    @Published public private(set) var caption: String = ""

    let gateway: GatewayClient
    let player = VoicePlayer()
    let speaker = ReplySpeaker()
    private let microphone = HandsFreeMicrophone()
    private let transcriber = LiveTranscriber()
    private var detector = SpeechDetector()
    private var watching: AnyCancellable?
    /// The reply being waited for or played: everything after this point in the chat.
    private var since = Date()
    private var replyId: String?
    private var appended = 0
    private var thinkingTimeout: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    /// The current turn began while the agent was talking (it's stopped once words are heard).
    private var interrupting = false
    private var listenedFor: TimeInterval = 0
    private let settleTime: TimeInterval = 2
    /// Without recognition: how much of the turn was clearly sound (noise blips aren't sent).
    private var turnSeconds: TimeInterval = 0
    private var loudSeconds: TimeInterval = 0

    public init(gateway: GatewayClient) {
        self.gateway = gateway
    }

    public func start() async {
        guard await AVAudioApplication.requestRecordPermission() else {
            phase = .failed("Lekora needs the microphone for hands-free. You can allow it in Settings › Lekora.")
            return
        }
        microphone.onLevel = { [weak self] level, duration in self?.heard(level: level, duration: duration) }
        if await transcriber.prepare() {
            HandsFreeLog.log.info("Hands-free: on-device recognition (\(self.transcriber.kind ?? "?", privacy: .public))")
        } else {
            // No recognition here: only clearer, longer sound counts as talking.
            HandsFreeLog.log.info("Hands-free: no on-device recognition; sending recordings")
            detector.margin = 20
            detector.startAfter = 0.3
            detector.minimumTurn = 1.2
        }
        microphone.onBuffer = { [weak self] buffer in self?.transcriber.feed(buffer) }
        AudioSessionOwner.handsFree = true
        do {
            try microphone.start()
        } catch {
            AudioSessionOwner.handsFree = false
            phase = .failed("The microphone couldn't start: \(error.localizedDescription)")
            return
        }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
                self?.tick()
            }
        }
        // Follow the chat for the agent's replies.
        watching = gateway.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.followReply() }
        }
        phase = .listening
    }

    public func end() {
        thinkingTimeout?.cancel()
        ticker?.cancel()
        transcriber.stop()
        AudioSessionOwner.handsFree = false
        watching = nil
        microphone.stop()
        player.stop()
        speaker.stop()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    // MARK: - Listening

    private func heard(level dB: Float, duration: TimeInterval) {
        level = VoiceWaveform.level(fromDecibels: dB)
        listenedFor += duration
        guard !muted else { return }
        // The first moments measure the room (opening the microphone can click).
        if listenedFor < settleTime {
            _ = detector.feed(level: dB, duration: duration)
            detector.reset()
            return
        }
        if phase == .hearing {
            turnSeconds += duration
            if dB > detector.threshold { loudSeconds += duration }
        }
        switch phase {
        case .listening, .speaking, .thinking:
            if detector.feed(level: dB, duration: duration) == .started {
                interrupting = phase != .listening
                turnSeconds = 0
                loudSeconds = 0
                microphone.beginTurn()
                transcriber.beginTurn()
                phase = .hearing
            }
        case .hearing:
            // Talking over the agent stops it, but only once real words are heard (a cough, a
            // door or its own voice leaking back doesn't); echo cancellation keeps its voice out.
            if interrupting, !transcriber.ready || !transcriber.wordsSoFar.isEmpty {
                player.stop()
                speaker.stop()
                interrupting = false
            }
            if detector.feed(level: dB, duration: duration) == .ended {
                finishTurn()
            } else if !detector.talking {
                microphone.dropTurn()  // too short to be meant
                phase = interrupting ? .speaking : .listening
                interrupting = false
            }
        default:
            break
        }
    }

    private func finishTurn() {
        guard let turn = microphone.endTurn(trailingSilence: detector.endAfter) else {
            phase = .listening
            return
        }
        let wasInterrupting = interrupting
        interrupting = false
        detector.reset()
        Task {
            if transcriber.ready {
                // Words, not loudness, decide: noise with nothing said is never sent.
                let words = await transcriber.endTurn()
                try? FileManager.default.removeItem(at: turn.url)
                HandsFreeLog.log.info("Hands-free turn: \(words.isEmpty ? "no words, dropped" : "sent \(words.count) characters", privacy: .public)")
                guard !words.isEmpty else {
                    phase = wasInterrupting && (player.isPlaying || speaker.speakingId != nil) ? .speaking : .listening
                    return
                }
                beginWaiting(caption: words)
                await gateway.sendMessage(words, handsFree: true)  // straight to the agent: no upload
                return
            }
            // No recognition on this iPhone: send the recording (Hermes transcribes it), but
            // only a real stretch of sound.
            // Leaving out the quiet that ended the turn.
            let spoken = max(turnSeconds - detector.endAfter, 0.1)
            let speechy = min(loudSeconds / spoken, 1)
            HandsFreeLog.log.info("Hands-free turn: recording of \(turn.duration, privacy: .public)s, \(Int(speechy * 100), privacy: .public)% sound")
            guard turn.duration >= 1.2, speechy >= 0.35 else {
                HandsFreeLog.log.info("Hands-free turn: dropped (too short or mostly background)")
                try? FileManager.default.removeItem(at: turn.url)
                phase = .listening
                return
            }
            HandsFreeLog.log.info("Hands-free turn: sent the recording")
            beginWaiting(caption: "…")
            do {
                try await gateway.sendVoiceNote(at: turn.url, duration: turn.duration, waveform: turn.waveform, handsFree: true)
            } catch {
                caption = "That didn't send: \(error.localizedDescription)"
                phase = .listening
            }
            try? FileManager.default.removeItem(at: turn.url)
        }
    }

    private func beginWaiting(caption text: String) {
        player.stop()
        speaker.stop()
        phase = .thinking
        caption = text
        since = Date()
        replyId = nil
        appended = 0
        thinkingTimeout?.cancel()
        thinkingTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            guard !Task.isCancelled, let self, self.phase == .thinking else { return }
            self.phase = .listening  // no reply after two minutes: your turn again
        }
    }

    // MARK: - The agent's reply

    private var messages: [ChatEntry] { gateway.timeline.entries(for: gateway.activeProfileId) }

    /// Watches the chat after your turn: your transcript, then the agent's reply, played as it comes.
    private func followReply() {
        if phase == .thinking, let mine = messages.last(where: { $0.role == .user }), let heard = mine.transcript {
            caption = heard
        }
        guard phase == .thinking || phase == .speaking,
              let reply = messages.last(where: { $0.role == .agent && ($0.date ?? .distantPast) >= since.addingTimeInterval(-1) })
        else { return }
        if replyId != reply.id {
            replyId = reply.id
            appended = 0
        }
        let key = reply.voiceKey ?? reply.id
        let isVoice = reply.voicing != nil || gateway.voiceReplies[key] != nil || reply.spoken != nil
        if isVoice {
            let parts = (reply.spoken?.isEmpty == false ? reply.spoken : gateway.liveSpeech[key]) ?? []
            let done = reply.spoken != nil || reply.voiceProblem != nil
            if appended < parts.count { playNext(parts, of: reply.id) }
            player.expectsMore = !done
            if done, appended >= parts.count, !player.isPlaying, phase == .speaking || parts.isEmpty {
                replyFinished()
            }
        } else {
            // No Hermes voice: the iPhone voice reads it as it's written.
            thinkingTimeout?.cancel()
            phase = .speaking
            let settings = gateway.voiceSettings[gateway.activeProfileId] ?? .standard
            speaker.follow(id: reply.id, text: reply.text, final: reply.status != .streaming, settings: settings)
            caption = SpeechText.clean(reply.text)
            if reply.status != .streaming, speaker.speakingId == nil { replyFinished() }
        }
        if isVoice { caption = SpeechText.clean(reply.text) }
    }

    private var fetching = false

    private func playNext(_ parts: [ChatFile], of id: String) {
        guard !fetching else { return }
        fetching = true
        Task {
            defer { fetching = false }
            while appended < parts.count, replyId == id {
                guard let url = try? await gateway.fileURL(for: parts[appended]) else { break }
                thinkingTimeout?.cancel()
                phase = .speaking
                player.append(id: id, url: url)
                appended += 1
            }
            followReply()
        }
    }

    /// The reply is done: your turn.
    private func replyFinished() {
        guard phase == .speaking || phase == .thinking else { return }
        phase = .listening
        detector.reset()
    }

    /// Checked a few times a second while speaking: playback ending means your turn.
    func tick() {
        guard phase == .speaking else { return }
        if !player.isPlaying && speaker.speakingId == nil && !fetching {
            followReply()
            if phase == .speaking, let reply = messages.last(where: { $0.id == replyId }),
               reply.spoken != nil || reply.voicing == nil, appended >= (reply.spoken?.count ?? 0) {
                replyFinished()
            }
        }
    }
}
