import Foundation
import AVFoundation
import Combine

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

/// Records one voice note at a time (AAC in .m4a), with live levels for the waveform.
@MainActor
public final class VoiceRecorder: ObservableObject {
    @Published public private(set) var isRecording = false
    @Published public private(set) var elapsed: TimeInterval = 0
    /// The newest levels (0…1), for the live waveform.
    @Published public private(set) var levels: [Double] = []

    public static let maxDuration: TimeInterval = 600
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var allLevels: [Double] = []

    public init() {}

    /// Asks for the microphone the first time; false if the user said no.
    public func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    public func start() throws {
        guard !isRecording else { return }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        #endif
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Voice note \(Self.stamp()).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.record(forDuration: Self.maxDuration) else {
            throw NSError(domain: "Lekora", code: 1, userInfo: [NSLocalizedDescriptionKey: "The microphone couldn't start."])
        }
        self.recorder = recorder
        allLevels = []
        levels = []
        elapsed = 0
        isRecording = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    private func sample() {
        guard let recorder, isRecording else { return }
        recorder.updateMeters()
        let level = VoiceWaveform.level(fromDecibels: recorder.averagePower(forChannel: 0))
        allLevels.append(level)
        levels = Array(allLevels.suffix(40))
        elapsed = recorder.currentTime
        if !recorder.isRecording { isRecording = false }  // reached the 10-minute limit
    }

    /// Stops and returns the recording, its length and waveform; nil if it was too short.
    public func finish() -> (url: URL, duration: TimeInterval, waveform: [Double])? {
        guard let recorder else { return nil }
        let duration = max(recorder.currentTime, elapsed)
        stopRecorder()
        guard duration >= 0.5 else {
            try? FileManager.default.removeItem(at: recorder.url)
            return nil
        }
        return (recorder.url, duration, VoiceWaveform.bars(allLevels))
    }

    /// Stops and throws the recording away (slid to cancel).
    public func cancel() {
        guard let recorder else { return }
        stopRecorder()
        try? FileManager.default.removeItem(at: recorder.url)
    }

    private func stopRecorder() {
        timer?.invalidate()
        timer = nil
        recorder?.stop()
        recorder = nil
        isRecording = false
    }

    private static func stamp() -> String {
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return format.string(from: Date())
    }
}

/// Plays one voice note at a time, with its position for the bubble's waveform.
@MainActor
public final class VoicePlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    /// The message whose voice note is loaded.
    @Published public private(set) var currentId: String?
    @Published public private(set) var isPlaying = false
    /// 0…1 through the current one.
    @Published public private(set) var progress: Double = 0

    private var player: AVAudioPlayer?
    private var timer: Timer?

    public override init() {}

    public func toggle(id: String, url: URL) {
        if currentId == id, let player {
            if player.isPlaying { pause() } else { resume() }
            return
        }
        play(id: id, url: url, from: 0)
    }

    public func play(id: String, url: URL, from fraction: Double) {
        stop()
        do {
            #if os(iOS)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.currentTime = player.duration * min(max(fraction, 0), 1)
            self.player = player
            currentId = id
            progress = fraction
            resume()
        } catch {
            stop()
        }
    }

    /// Drags on the waveform: jump there (and keep playing if it was).
    public func seek(id: String, url: URL, to fraction: Double) {
        guard currentId == id, let player else {
            play(id: id, url: url, from: fraction)
            return
        }
        player.currentTime = player.duration * min(max(fraction, 0), 1)
        progress = fraction
    }

    private func resume() {
        guard let player else { return }
        player.play()
        isPlaying = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player, player.duration > 0 else { return }
                self.progress = player.currentTime / player.duration
            }
        }
    }

    public func pause() {
        player?.pause()
        isPlaying = false
        timer?.invalidate()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil
        isPlaying = false
        currentId = nil
        progress = 0
    }

    public nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.timer?.invalidate()
            self.isPlaying = false
            self.progress = 0
            self.player?.currentTime = 0
        }
    }
}
