import Foundation
import AVFoundation
import Combine

/// Who sets the iPhone's audio session. While a hands-free conversation runs it owns it
/// (microphone and speaker together, with echo cancellation), so playing doesn't switch it.
@MainActor
public enum AudioSessionOwner {
    /// A call is on: only the call's own players make sound (owner, 2026-11-13: a voice note
    /// that was playing went on under the call). Turning it on stops every other player.
    public static var handsFree = false {
        didSet {
            if handsFree, !oldValue { NotificationCenter.default.post(name: callStarted, object: nil) }
        }
    }
    public static let callStarted = Notification.Name("LekoraCallStarted")
}

/// Recording voice notes and playing them back (docs/voice.md).
public enum VoiceWaveform {
    /// Microphone levels (dB, about -60…0) to 0…1.
    public static func level(fromDecibels db: Float) -> Double {
        let floor: Float = -50
        guard db > floor else { return 0.02 }
        return Double(min(max((db - floor) / -floor, 0.02), 1))
    }

    /// Many levels to `count` bars (each the loudest of its slice); fewer are kept as they are.
    public static func bars(_ levels: [Double], count: Int = 48) -> [Double] {
        guard levels.count > count, count > 0 else { return levels }
        let size = Double(levels.count) / Double(count)
        return (0..<count).map { bar in
            let start = Int(Double(bar) * size)
            let end = max(Int(Double(bar + 1) * size), start + 1)
            return levels[start..<min(end, levels.count)].max() ?? 0
        }
    }
}

/// Records one voice note at a time (AAC in .m4a), as in Messages: tap to start, stop to
/// review, record more onto the end, then send or throw away. Live levels for the waveform.
@MainActor
public final class VoiceRecorder: ObservableObject {
    /// A stopped recording, waiting to be sent or thrown away.
    public struct Draft: Equatable {
        public let url: URL
        public let duration: TimeInterval
        public let waveform: [Double]
    }

    @Published public private(set) var isRecording = false
    /// Length so far (including earlier parts of the same note).
    @Published public private(set) var elapsed: TimeInterval = 0
    /// The newest levels (0…1), for the live waveform.
    @Published public private(set) var levels: [Double] = []
    @Published public private(set) var draft: Draft?
    /// True while a stopped part is being joined onto the note.
    @Published public private(set) var isFinishing = false

    public static let maxDuration: TimeInterval = 600
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var allLevels: [Double] = []

    public init() {}

    /// Asks for the microphone the first time; false if the user said no.
    public func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    /// Starts recording, or records more onto the end of the stopped note.
    public func start() throws {
        guard !isRecording, !isFinishing else { return }
        let before = draft?.duration ?? 0
        guard before < Self.maxDuration - 1 else { return }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        #endif
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-part-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.record(forDuration: Self.maxDuration - before) else {
            throw NSError(domain: "Lekora", code: 1, userInfo: [NSLocalizedDescriptionKey: "The microphone couldn't start."])
        }
        self.recorder = recorder
        if draft == nil { allLevels = [] }
        levels = Array(allLevels.suffix(60))
        elapsed = before
        isRecording = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    private func sample() {
        guard let recorder, isRecording else { return }
        recorder.updateMeters()
        allLevels.append(VoiceWaveform.level(fromDecibels: recorder.averagePower(forChannel: 0)))
        levels = Array(allLevels.suffix(60))
        elapsed = (draft?.duration ?? 0) + recorder.currentTime
        if !recorder.isRecording { Task { await stop() } }  // reached the 10-minute limit
    }

    /// Stops recording: the note (with any earlier parts) becomes the draft to review.
    public func stop() async {
        guard let recorder else { return }
        let part = recorder.url
        let partLength = recorder.currentTime
        stopRecorder()
        guard partLength >= 0.3 else {  // a slip of the finger adds nothing
            try? FileManager.default.removeItem(at: part)
            return
        }
        guard let earlier = draft else {
            // The first part: ready straight away (no waiting, so the review bar appears smoothly).
            draft = Draft(url: part, duration: partLength, waveform: VoiceWaveform.bars(allLevels))
            return
        }
        // More recorded onto the end: the note stays shown (Send waits) while the parts are joined.
        isFinishing = true
        defer { isFinishing = false }
        let joined = (try? await Self.join(earlier.url, part)) ?? earlier.url
        try? FileManager.default.removeItem(at: part)
        if joined != earlier.url { try? FileManager.default.removeItem(at: earlier.url) }
        let length = (try? await AVURLAsset(url: joined).load(.duration).seconds) ?? (earlier.duration + partLength)
        draft = Draft(url: joined, duration: length, waveform: VoiceWaveform.bars(allLevels))
    }

    /// Hands over the finished note (named for the chat) and clears it.
    public func takeDraft() -> Draft? {
        guard let draft else { return nil }
        self.draft = nil
        allLevels = []
        let named = FileManager.default.temporaryDirectory.appendingPathComponent("Voice note \(Self.stamp()).m4a")
        try? FileManager.default.removeItem(at: named)
        guard (try? FileManager.default.moveItem(at: draft.url, to: named)) != nil else { return draft }
        return Draft(url: named, duration: draft.duration, waveform: draft.waveform)
    }

    /// Stops and throws everything away (the ×, or leaving the chat).
    public func discard() {
        if let recorder { try? FileManager.default.removeItem(at: recorder.url) }
        stopRecorder()
        if let draft { try? FileManager.default.removeItem(at: draft.url) }
        draft = nil
        allLevels = []
        levels = []
        elapsed = 0
    }

    private func stopRecorder() {
        timer?.invalidate()
        timer = nil
        recorder?.stop()
        recorder = nil
        isRecording = false
    }

    /// One recording after the other, as a new .m4a.
    private static func join(_ first: URL, _ second: URL) async throws -> URL {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw NSError(domain: "Lekora", code: 2)
        }
        var at = CMTime.zero
        for url in [first, second] {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first else { continue }
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: at)
            at = at + duration
        }
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw NSError(domain: "Lekora", code: 3)
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).m4a")
        try await export.export(to: out, as: .m4a)
        return out
    }

    private static func stamp() -> String {
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return format.string(from: Date())
    }
}

/// Plays one voice note at a time, with its position for the bubble's waveform. A note can be
/// several parts played one after the other (voice-mode replies), and parts can be added while
/// it plays (a reply still being spoken; docs/voice.md §2).
@MainActor
public final class VoicePlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    /// The message whose voice note is loaded.
    @Published public private(set) var currentId: String?
    @Published public private(set) var isPlaying = false
    /// 0…1 through the current one.
    @Published public private(set) var progress: Double = 0
    /// The note whose audio this iPhone couldn't play (shown, instead of a silent "playing").
    @Published public private(set) var failedId: String?

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var parts: [URL] = []
    private var lengths: [TimeInterval] = []
    private var index = 0
    /// Waiting for the next part of a reply still being spoken.
    private var waiting = false

    /// The call's own player (it plays during a call; every other one stays quiet).
    public var belongsToCall = false
    private var callObserver: NSObjectProtocol?

    public override init() {
        super.init()
        callObserver = NotificationCenter.default.addObserver(forName: AudioSessionOwner.callStarted, object: nil,
                                                              queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.belongsToCall else { return }
                self.stop()
            }
        }
    }

    private var total: TimeInterval { lengths.reduce(0, +) }

    public func toggle(id: String, url: URL) {
        toggle(id: id, urls: [url])
    }

    public func toggle(id: String, urls: [URL]) {
        if currentId == id, player != nil || waiting {
            if isPlaying { pause() } else { resume() }
            return
        }
        play(id: id, urls: urls, from: 0)
    }

    public func play(id: String, url: URL, from fraction: Double) {
        play(id: id, urls: [url], from: fraction)
    }

    public func play(id: String, urls: [URL], from fraction: Double) {
        stop()
        guard belongsToCall || !AudioSessionOwner.handsFree else { return }  // a call is on
        parts = urls
        lengths = urls.map { Self.length(of: $0) }
        currentId = id
        start(at: fraction)
    }

    /// Another part of the note `id` (a reply still being spoken): played after the others,
    /// or straight away if playback was waiting for it. Starts the note if nothing is playing.
    public func append(id: String, url: URL) {
        guard currentId == id else {
            if player == nil || !isPlaying { play(id: id, urls: [url], from: 0) }
            return
        }
        parts.append(url)
        lengths.append(Self.length(of: url))
        if waiting {
            waiting = false
            index = parts.count - 1
            load(index, at: 0)
            resume()
        }
    }

    /// Drags on the waveform: jump there (and keep playing if it was).
    public func seek(id: String, url: URL, to fraction: Double) {
        seek(id: id, urls: [url], to: fraction)
    }

    public func seek(id: String, urls: [URL], to fraction: Double) {
        guard currentId == id, !parts.isEmpty else {
            play(id: id, urls: urls, from: fraction)
            return
        }
        let wasPlaying = isPlaying
        start(at: fraction, play: wasPlaying)
        progress = fraction
    }

    private func start(at fraction: Double, play: Bool = true) {
        var target = total * min(max(fraction, 0), 1)
        var at = 0
        while at < lengths.count - 1, target >= lengths[at] {
            target -= lengths[at]
            at += 1
        }
        if at == index, let player {
            player.currentTime = min(target, player.duration)  // same part: just move (no audio restart)
        } else {
            index = at
            load(at, at: target)
        }
        if play, !(self.player?.isPlaying ?? false) { resume() }
    }

    private func load(_ part: Int, at time: TimeInterval) {
        timer?.invalidate()
        player?.stop()
        player = nil
        guard parts.indices.contains(part) else { return }
        do {
            #if os(iOS)
            // Only when it changes: setting it for every part can stall the screen.
            let session = AVAudioSession.sharedInstance()
            if !AudioSessionOwner.handsFree, session.category != .playback || session.mode != .spokenAudio {
                try session.setCategory(.playback, mode: .spokenAudio)
                try session.setActive(true)
            }
            #endif
            let next = try AVAudioPlayer(contentsOf: parts[part])
            next.delegate = self
            next.currentTime = min(time, next.duration)
            player = next
            if failedId == currentId { failedId = nil }
        } catch {
            player = nil
            failedId = currentId  // e.g. a format iPhone can't play
        }
    }

    private func resume() {
        // During a call nothing else plays, even a note that finished loading just now.
        if AudioSessionOwner.handsFree, !belongsToCall {
            isPlaying = false
            return
        }
        guard let player, player.play() else {
            isPlaying = false
            if player != nil { failedId = currentId }
            return
        }
        isPlaying = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard let player, total > 0 else { return }
        let before = lengths.prefix(index).reduce(0, +)
        progress = min((before + player.currentTime) / total, 1)
    }

    public func pause() {
        player?.pause()
        isPlaying = false
        waiting = false
        timer?.invalidate()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil
        isPlaying = false
        waiting = false
        currentId = nil
        progress = 0
        failedId = nil
        parts = []
        lengths = []
        index = 0
    }

    /// Whether more parts may still come for the playing note (set by the chat screen).
    public var expectsMore = false

    public nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.partEnded() }
    }

    private func partEnded() {
        if index + 1 < parts.count {
            index += 1
            load(index, at: 0)
            resume()
            return
        }
        if expectsMore {
            waiting = true  // the next part of the reply is still being spoken
            return
        }
        timer?.invalidate()
        isPlaying = false
        progress = 0
        index = 0
        load(0, at: 0)
    }

    static func length(of url: URL) -> TimeInterval {
        lengthNonisolated(of: url)
    }

    nonisolated static func lengthNonisolated(of url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }
}

extension VoiceWaveform {
    /// Bars for audio files (a voice-mode reply), read from the sound itself.
    public static func bars(of urls: [URL], count: Int = 48) -> [Double] {
        var levels: [Double] = []
        for url in urls {
            guard let file = try? AVAudioFile(forReading: url),
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
                  (try? file.read(into: buffer)) != nil, let samples = buffer.floatChannelData?[0] else { continue }
            let frames = Int(buffer.frameLength)
            let step = max(Int(file.processingFormat.sampleRate / 20), 1)  // 20 levels a second
            var start = 0
            while start < frames {
                let end = min(start + step, frames)
                var sum: Float = 0
                for i in start..<end { sum += samples[i] * samples[i] }
                let rms = sqrt(sum / Float(max(end - start, 1)))
                levels.append(level(fromDecibels: 20 * log10(max(rms, 0.000_01))))
                start = end
            }
        }
        return bars(levels, count: count)
    }
}
