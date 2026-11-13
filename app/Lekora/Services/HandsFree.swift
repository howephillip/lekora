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

    /// Measure the room again (the microphone's sound just changed).
    public mutating func remeasure() {
        reset()
        measured = false
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

    /// The agent's streamed voice (docs/voice.md §4), on its own audio engine: the microphone's
    /// engine stays input-only, exactly as when calls recognised speech (owner, 2026-11-13).
    let speech = StreamSpeaker()

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
        speech.stop()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        fileURL = nil
    }

    var isRunning: Bool { engine.isRunning }

    /// For the diagnostics line: what the microphone delivers.
    var formatDescription: String {
        let format = engine.inputNode.outputFormat(forBus: 0)
        return "\(Int(format.sampleRate)) Hz, \(format.channelCount) ch, voice processing \(engine.inputNode.isVoiceProcessingEnabled ? "on" : "off")"
    }


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
    /// Why recognition couldn't start, if it couldn't.
    private(set) var failure: String?
    /// For the diagnostics line: audio given so far and readings received.
    var stats: String { "recognizer heard \(Int(fedSeconds)) s, \(pieces.count) readings" }

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
            failure = error.localizedDescription
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

    /// Where this turn starts in the audio (seconds), for the sounds heard alongside.
    var turnStartSeconds: Double { turnStart }

    /// Talking ended: what was said in this turn (each piece with where it starts), once
    /// recognition has caught up.
    func endTurn() async -> [(start: Double, text: String)] {
        if let analyzer, let input {
            _ = input  // keep feeding: recognition goes on for the next turn
            try? await analyzer.finalize(through: CMTime(seconds: fedSeconds, preferredTimescale: 48_000))
        }
        return pieces.filter { $0.end > turnStart }
            .map { (start: $0.start, text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.text.isEmpty }
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

    let gateway: GatewayClient
    let player = VoicePlayer()
    let speaker = ReplySpeaker()
    private let microphone = HandsFreeMicrophone()
    private let transcriber = LiveTranscriber()
    private let sounds = SoundListener()
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
    /// This turn's timing (docs/voice.md §3, "Speed"), sent to the instance's log.
    private var turnEnded: Date?
    private var wordsReady: Date?
    private var sentAt: Date?
    private var audioArrived: Date?
    private var turnSounds = ""

    public init(gateway: GatewayClient) {
        self.gateway = gateway
    }

    /// A diagnostics line (never your words): on the iPhone's log and the Hermes instance's, so
    /// a call that misbehaves can be understood afterwards (docs/voice.md §3, "Diagnostics").
    private func note(_ line: String) {
        HandsFreeLog.log.info("\(line, privacy: .public)")
        gateway.reportVoiceLog(line, profileId: gateway.activeProfileId)
    }

    private var peak: Float = -100
    private var lastLevelNote: TimeInterval = 0

    public func start() async {
        guard await AVAudioApplication.requestRecordPermission() else {
            phase = .failed("Lekora needs the microphone for hands-free. You can allow it in Settings › Lekora.")
            return
        }
        microphone.onLevel = { [weak self] level, duration in self?.heard(level: level, duration: duration) }
        if await transcriber.prepare() {
            note("call started: on-device recognition (\(transcriber.kind ?? "?"))")
            // The words tell a turn from noise, so the end of one can come sooner.
            detector.endAfter = 0.9
        } else {
            // No recognition here: only clearer, longer sound counts as talking.
            note("call started: no on-device recognition (\(transcriber.failure ?? "not available")); sending recordings")
            detector.margin = 20
            detector.startAfter = 0.3
            detector.minimumTurn = 1.2
        }
        // Direct voice: the reply's sound as it's made (docs/voice.md §4).
        gateway.onVoiceStream = { [weak self] chunk in self?.streamed(chunk) }
        microphone.speech.onIdle = { [weak self] in self?.tick() }
        microphone.onBuffer = { [weak self] buffer in
            guard let self else { return }
            self.transcriber.feed(buffer)
            if self.transcriber.ready { self.sounds.feed(buffer) }  // laughs etc. go with the words
        }
        AudioSessionOwner.handsFree = true
        do {
            try microphone.start()
        } catch {
            AudioSessionOwner.handsFree = false
            phase = .failed("The microphone couldn't start: \(error.localizedDescription)")
            return
        }
        note("microphone: \(microphone.formatDescription)")
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
        sounds.stop()
        gateway.onVoiceStream = nil
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
        peak = max(peak, dB)
        if listenedFor - lastLevelNote >= (lastLevelNote == 0 ? 3 : 10) {
            // Every 10 s: is the microphone hearing anything, and what counts as talking.
            note(String(format: "sound: loudest %.0f dB, room %.0f dB, talking above %.0f dB; %@; %@",
                        peak, detector.noiseFloor, detector.threshold, "\(phase)", transcriber.stats))
            peak = -100
            lastLevelNote = listenedFor
        }
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
            if detector.feed(level: heardOverAgent(dB), duration: duration) == .started {
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
            // Its voice leaking back can be heard as words, so it takes two words that aren't
            // the agent's own (owner, 2026-11-13: random noises interrupted it).
            if interrupting, !transcriber.ready || EchoFilter.fresh(heard: transcriber.wordsSoFar, agent: agentText) >= 2 {
                player.stop()
                speaker.stop()
                microphone.speech.stop()
                interrupting = false
            }
            if detector.feed(level: interrupting ? heardOverAgent(dB) : dB, duration: duration) == .ended {
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
        let ended = Date()
        Task {
            if transcriber.ready {
                // Words, not loudness, decide: noise with nothing said is never sent.
                let pieces = await transcriber.endTurn()
                try? FileManager.default.removeItem(at: turn.url)
                let said = pieces.map(\.text).joined(separator: " ")
                if wasInterrupting, EchoFilter.fresh(heard: said, agent: agentText) < 2 {
                    // Only the agent's own words (or a stray one) while it talked: not you.
                    note("turn of \(String(format: "%.1f", turn.duration)) s while the agent talked: its own voice or noise, dropped")
                    phase = agentTalking ? .speaking : .listening
                    return
                }
                guard !pieces.isEmpty else {
                    note("turn of \(String(format: "%.1f", turn.duration)) s: no words recognised, dropped (\(transcriber.stats))")
                    phase = wasInterrupting && agentTalking ? .speaking : .listening
                    return
                }
                // How it was said: laughs, sighs… where they happened.
                let heard = await sounds.sounds(since: transcriber.turnStartSeconds)
                let words = SoundCue.weave(words: pieces, sounds: heard)
                turnSounds = SoundCue.summary(sounds.peaks(since: transcriber.turnStartSeconds))
                let tags = Set(heard.map(\.tag)).sorted().joined(separator: " ")
                note("turn of \(String(format: "%.1f", turn.duration)) s: sent \(words.count) characters\(tags.isEmpty ? "" : ", heard \(tags)")")
                beginWaiting()
                turnEnded = ended
                wordsReady = Date()
                await gateway.sendMessage(words, handsFree: true)  // straight to the agent: no upload
                sentAt = Date()
                return
            }
            // No recognition on this iPhone: send the recording (Hermes transcribes it), but
            // only a real stretch of sound.
            // Leaving out the quiet that ended the turn.
            let spoken = max(turnSeconds - detector.endAfter, 0.1)
            let speechy = min(loudSeconds / spoken, 1)
            note("turn: recording of \(String(format: "%.1f", turn.duration)) s, \(Int(speechy * 100))% sound")
            guard turn.duration >= 1.2, speechy >= 0.35 else {
                note("turn dropped (too short or mostly background)")
                try? FileManager.default.removeItem(at: turn.url)
                phase = .listening
                return
            }
            note("turn: sent the recording")
            beginWaiting()
            do {
                try await gateway.sendVoiceNote(at: turn.url, duration: turn.duration, waveform: turn.waveform, handsFree: true)
            } catch {
                note("turn didn't send: \(error.localizedDescription)")
                phase = .listening
            }
            try? FileManager.default.removeItem(at: turn.url)
        }
    }

    private func beginWaiting() {
        player.stop()
        speaker.stop()
        microphone.speech.stop()
        // Whatever of an earlier reply is still arriving isn't played into this turn.
        staleStreams.formUnion(seenStreams)
        streamKey = nil
        streamedParts = []
        playedFiles = []
        phase = .thinking
        turnEnded = nil
        wordsReady = nil
        sentAt = nil
        audioArrived = nil
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
        guard phase == .thinking || phase == .speaking,
              let reply = messages.last(where: { $0.role == .agent && ($0.date ?? .distantPast) >= since.addingTimeInterval(-1) })
        else { return }
        if replyId != reply.id {
            replyId = reply.id
            appended = 0
        }
        let key = reply.voiceKey ?? reply.id
        let isVoice = reply.voicing != nil || gateway.voiceReplies[key] != nil || reply.spoken != nil
        // A voice reply is only ever heard in the agent's voice: never the iPhone's on top.
        if isVoice, speaker.speakingId == reply.id { speaker.stop() }
        if isVoice, gateway.streamingReplies.contains(key) {
            followStreamed(reply, key: key)
        } else if isVoice {
            let parts = (reply.spoken?.isEmpty == false ? reply.spoken : gateway.liveSpeech[key]) ?? []
            let done = reply.spoken != nil || reply.voiceProblem != nil
            if !parts.isEmpty, audioArrived == nil { audioArrived = Date() }
            if appended < parts.count { playNext(parts, of: reply.id) }
            player.expectsMore = !done
            if done, appended >= parts.count, !player.isPlaying, phase == .speaking || parts.isEmpty {
                replyFinished()
            }
        } else if gateway.hermesVoice[gateway.activeProfileId]?.available != false, reply.status == .streaming {
            // The agent has (or may have) its own voice: wait for it rather than starting the
            // iPhone voice, which would then talk on top of it (owner, 2026-11-13).
            return
        } else {
            // No Hermes voice (or a finished reply that never got one): the iPhone voice reads it.
            thinkingTimeout?.cancel()
            phase = .speaking
            let settings = gateway.voiceSettings[gateway.activeProfileId] ?? .standard
            speaker.follow(id: reply.id, text: reply.text, final: reply.status != .streaming, settings: settings)
            if reply.status != .streaming, speaker.speakingId == nil { replyFinished() }
        }
    }

    private var fetching = false

    // MARK: - Direct voice: sound streamed as it's made (docs/voice.md §4)

    private var streamKey: String?
    /// Parts ("key#index") heard as a stream; their saved files aren't played again.
    private var streamedParts: Set<String> = []
    private var playedFiles: Set<String> = []
    private var seenStreams: Set<String> = []
    private var staleStreams: Set<String> = []

    /// While the agent talks, only sound clearly louder than its own voice leaking back from
    /// the speaker counts as you (you close to the phone: about -20 dB; its voice: -30 to -45).
    private func heardOverAgent(_ dB: Float) -> Float {
        guard agentTalking || phase == .speaking, dB < -30 else { return dB }
        return min(dB, detector.threshold - 1)
    }

    /// What the agent is saying now (to tell its voice leaking back from yours).
    private var agentText: String { messages.last(where: { $0.id == replyId })?.text ?? "" }

    private var agentTalking: Bool { player.isPlaying || speaker.speakingId != nil || microphone.speech.isSpeaking }

    private func streamed(_ chunk: VoiceStreamData) {
        guard phase == .thinking || phase == .speaking || (phase == .hearing && interrupting) else { return }
        guard !staleStreams.contains(chunk.message_id) else { return }
        seenStreams.insert(chunk.message_id)
        // This turn's reply (or the agent's next message in it): queued after what's playing.
        streamKey = chunk.message_id
        if chunk.last == true { microphone.speech.flush() }
        guard let pcm = Data(base64Encoded: chunk.data), !pcm.isEmpty else { return }
        streamedParts.insert("\(chunk.message_id)#\(chunk.index)")
        let first = audioArrived == nil
        if first { audioArrived = Date() }
        thinkingTimeout?.cancel()
        microphone.speech.play(pcm: pcm, rate: chunk.rate)
        if phase == .thinking { phase = .speaking }
        if first { reportTiming() }
    }

    /// A streamed reply: parts that weren't streamed (the voice service failed) play from their
    /// files; it's over once it's saved and everything has been heard.
    private func followStreamed(_ reply: ChatEntry, key: String) {
        let parts = (reply.spoken?.isEmpty == false ? reply.spoken : gateway.liveSpeech[key]) ?? []
        for (index, part) in parts.enumerated()
        where !streamedParts.contains("\(key)#\(index)") && !playedFiles.contains(part.file_id) {
            playedFiles.insert(part.file_id)
            fetching = true
            Task {
                defer { fetching = false }
                guard let url = try? await gateway.fileURL(for: part) else { return }
                thinkingTimeout?.cancel()
                microphone.speech.play(file: url)
                if phase == .thinking { phase = .speaking }
            }
        }
        let done = reply.spoken != nil || reply.voiceProblem != nil
        if done, !fetching, !microphone.speech.isSpeaking, phase == .speaking || (parts.isEmpty && reply.voiceProblem != nil) {
            replyFinished()
        }
    }

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
                if appended == 0 { reportTiming() }
                appended += 1
            }
            followReply()
        }
    }

    /// The first sound of the reply is playing: how long each step took on this side.
    private func reportTiming() {
        guard let ended = turnEnded, let words = wordsReady, let sent = sentAt else { return }
        let now = Date()
        let arrived = audioArrived ?? now
        let timing = VoiceTimingData(
            silence_wait: detector.endAfter,
            recognize: words.timeIntervalSince(ended),
            audio_received: arrived.timeIntervalSince(sent),
            playing: now.timeIntervalSince(arrived),
            total: now.timeIntervalSince(ended) + detector.endAfter,
            sounds: turnSounds.isEmpty ? nil : turnSounds)
        HandsFreeLog.log.info("Hands-free timing: \(timing.total, format: .fixed(precision: 1), privacy: .public)s from your last word to the first sound")
        gateway.reportVoiceTiming(timing, profileId: gateway.activeProfileId)
        turnEnded = nil
    }


    /// The reply is done: your turn.
    private func replyFinished() {
        guard phase == .speaking || phase == .thinking else { return }
        phase = .listening
        detector.reset()
    }

    /// Checked a few times a second while speaking: playback ending means your turn.
    func tick() {
        guard phase == .speaking else { silentSince = nil; return }
        guard !agentTalking, !fetching else { silentSince = nil; return }
        // Nothing playing: the reply decides whether it's over (all its sound heard and saved).
        // A gap while more is on its way (slow internet, the next sentence) is not the end
        // (owner, 2026-11-13: replies stopped and the call went back to listening).
        followReply()
        guard phase == .speaking else { return }
        let now = Date()
        if let since = silentSince, now.timeIntervalSince(since) > 20 {
            note("reply: nothing more arrived for 20 s, your turn")
            replyFinished()
        } else if silentSince == nil {
            silentSince = now
        }
    }
    private var silentSince: Date?
}


/// Plays the agent's streamed voice as it arrives (docs/voice.md §4): 16-bit mono PCM pieces,
/// and whole files for parts that weren't streamed, one after another.
@MainActor
final class StreamSpeaker {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private var queued = 0
    private var generation = 0
    /// A little sound is kept in hand before playing, so uneven arrival over the internet
    /// doesn't stutter (owner, 2026-11-13); after running dry, a little less to resume.
    private var holding: [AVAudioPCMBuffer] = []
    private var heldSeconds: Double = 0
    private var flowing = false
    private let startAfter: Double = 0.5
    private let resumeAfter: Double = 0.3
    /// Everything queued has been heard.
    var onIdle: (() -> Void)?
    var isSpeaking: Bool { queued > 0 || !holding.isEmpty }

    private func ready(rate: Double) -> AVAudioFormat? {
        if let format, format.sampleRate == rate, engine.isRunning { return format }
        guard queued == 0 || format == nil, let wanted = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else {
            return format
        }
        if format == nil { engine.attach(node) } else { node.stop(); engine.disconnectNodeOutput(node) }
        engine.connect(node, to: engine.mainMixerNode, format: wanted)
        format = wanted
        if !engine.isRunning {
            engine.prepare()
            do { try engine.start() } catch {
                HandsFreeLog.log.error("Streamed voice couldn't start: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        return wanted
    }

    func play(pcm: Data, rate: Int) {
        guard rate > 0, let format = ready(rate: Double(rate)) else { return }
        let frames = pcm.count / 2
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let out = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<frames { out[i] = Float(Int16(littleEndian: samples[i])) / 32_768 }
        }
        hold(buffer)
    }

    /// The end of a streamed part: play whatever is held.
    func flush() {
        guard !holding.isEmpty else { return }
        flowing = true
        let held = holding
        holding = []
        heldSeconds = 0
        held.forEach(schedule)
    }

    private func hold(_ buffer: AVAudioPCMBuffer) {
        if flowing {
            schedule(buffer)
            return
        }
        holding.append(buffer)
        heldSeconds += Double(buffer.frameLength) / buffer.format.sampleRate
        if heldSeconds >= (generation == startedGeneration ? resumeAfter : startAfter) {
            startedGeneration = generation
            flush()
        }
    }
    private var startedGeneration = -1

    func play(file url: URL) {
        guard let file = try? AVAudioFile(forReading: url),
              let target = ready(rate: format?.sampleRate ?? file.processingFormat.sampleRate),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: input)) != nil,
              let converter = AVAudioConverter(from: file.processingFormat, to: target) else { return }
        let capacity = AVAudioFrameCount(Double(input.frameLength) * target.sampleRate / file.processingFormat.sampleRate) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var given = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if given { status.pointee = .endOfStream; return nil }
            given = true
            status.pointee = .haveData
            return input
        }
        if error == nil, output.frameLength > 0 {
            flush()
            schedule(output)
        }
    }

    private func schedule(_ buffer: AVAudioPCMBuffer) {
        queued += 1
        let current = generation
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                self.queued = max(self.queued - 1, 0)
                if self.queued == 0 {
                    self.flowing = false  // ran dry: hold a little again before resuming
                    self.onIdle?()
                }
            }
        }
        if !node.isPlaying { node.play() }
    }

    /// Stop at once (you talked over it, or the call ended).
    func stop() {
        generation += 1
        queued = 0
        holding = []
        heldSeconds = 0
        flowing = false
        node.stop()
    }
}


/// Telling your words from the agent's own voice leaking back into the microphone.
public enum EchoFilter {
    static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init)
    }

    /// How many of the words heard aren't in what the agent is saying.
    public static func fresh(heard: String, agent: String) -> Int {
        let theirs = Set(words(agent))
        return words(heard).filter { !theirs.contains($0) }.count
    }
}
