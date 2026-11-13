import Foundation
import AVFoundation
import SoundAnalysis

/// Laughs, sighs, gasps and the like during hands-free (docs/voice.md §3, "The vibe"): heard
/// with Apple's built-in sound recognition on the iPhone (free, nothing leaves the phone), and
/// written into what you said where they happened, e.g. "that's hilarious [laughs] okay so…",
/// so the agent knows how it was said, not just the words.
public enum SoundCue {
    /// Apple's sound names → what the agent reads, and how sure the iPhone must be.
    static let tags: [String: (tag: String, confidence: Double)] = [
        "laughter": ("[laughs]", 0.6),
        "belly_laugh": ("[laughs]", 0.6),
        "giggling": ("[giggles]", 0.6),
        "snicker": ("[chuckles]", 0.6),
        "chuckle_chortle": ("[chuckles]", 0.6),
        "sigh": ("[sighs]", 0.6),
        "gasp": ("[gasps]", 0.6),
        "crying_sobbing": ("[crying]", 0.6),
        "whispering": ("[whispering]", 0.75),
        "shout": ("[shouting]", 0.75),
        "yell": ("[shouting]", 0.75),
        "screaming": ("[screams]", 0.75),
        "singing": ("[singing]", 0.7),
        "humming": ("[humming]", 0.7),
        "whistling": ("[whistles]", 0.7),
        "clapping": ("[claps]", 0.7),
        "applause": ("[claps]", 0.7),
    ]

    /// The words of a turn (each piece with where it starts, in seconds) with the sounds heard
    /// woven in by time. The same sound heard in overlapping moments counts once.
    public static func weave(words: [(start: Double, text: String)], sounds: [(time: Double, tag: String)]) -> String {
        var merged: [(time: Double, tag: String)] = []
        for sound in sounds.sorted(by: { $0.time < $1.time }) {
            if let last = merged.last, last.tag == sound.tag, sound.time - last.time < 2.5 { continue }
            merged.append(sound)
        }
        var out: [String] = []
        var next = 0
        for piece in words.sorted(by: { $0.start < $1.start }) {
            while next < merged.count, merged[next].time < piece.start {
                out.append(merged[next].tag)
                next += 1
            }
            out.append(piece.text)
        }
        out += merged[next...].map(\.tag)
        return out.joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// Listens alongside the speech recognizer, on the same audio, on its own queue.
final class SoundListener: NSObject, SNResultsObserving, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.lekora.sounds")
    private let lock = NSLock()
    private var analyzer: SNAudioStreamAnalyzer?
    private var format: AVAudioFormat?
    private var framesFed: AVAudioFramePosition = 0
    /// Seconds of audio before the current analyzer started (if the microphone's format changed).
    private var offset: Double = 0
    private var fedSeconds: Double = 0
    private var unavailable = false
    private var heard: [(time: Double, tag: String)] = []

    func feed(_ buffer: AVAudioPCMBuffer) {
        queue.async { [self] in
            guard !unavailable else { return }
            if analyzer == nil || format != buffer.format {
                let fresh = SNAudioStreamAnalyzer(format: buffer.format)
                do {
                    let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
                    // Shorter moments than the default 3 s, so a laugh lands near its words.
                    request.windowDuration = CMTime(seconds: 1.5, preferredTimescale: 48_000)
                    request.overlapFactor = 0.5
                    try fresh.add(request, withObserver: self)
                } catch {
                    unavailable = true
                    HandsFreeLog.log.error("Sound recognition couldn't start: \(error.localizedDescription, privacy: .public)")
                    return
                }
                analyzer = fresh
                format = buffer.format
                offset = fedSeconds
                framesFed = 0
            }
            analyzer?.analyze(buffer, atAudioFramePosition: framesFed)
            framesFed += AVAudioFramePosition(buffer.frameLength)
            fedSeconds += Double(buffer.frameLength) / buffer.format.sampleRate
        }
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        // The likeliest of the sounds that mean something, if the iPhone is sure enough.
        let best = result.classifications
            .compactMap { item -> (tag: String, confidence: Double)? in
                guard let rule = SoundCue.tags[item.identifier], item.confidence >= rule.confidence else { return nil }
                return (rule.tag, item.confidence)
            }
            .max { $0.confidence < $1.confidence }
        guard let best else { return }
        let time = offset + result.timeRange.start.seconds + result.timeRange.duration.seconds / 2
        lock.lock()
        heard.append((time, best.tag))
        if heard.count > 200 { heard.removeFirst(heard.count - 200) }
        lock.unlock()
    }

    /// Sounds heard from `start` (seconds of audio) on, once the audio given so far is analysed.
    func sounds(since start: Double) async -> [(time: Double, tag: String)] {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async { done.resume() }
        }
        return lock.withLock { heard.filter { $0.time >= start } }
    }

    func stop() {
        queue.async { [self] in
            analyzer?.removeAllRequests()
            analyzer = nil
            unavailable = true
        }
    }
}
