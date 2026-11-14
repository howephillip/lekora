import Foundation
import AVFoundation
import Combine

/// Turning replies into speech (docs/voice.md §2).
public enum SpeechText {
    /// What to say for a piece of Markdown: no symbols, link text without the address, code
    /// blocks skipped.
    public static func clean(_ markdown: String) -> String {
        var text = markdown
        text = text.replacingOccurrences(of: #"```[\s\S]*?(```|$)"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"https?://\S+"#, with: "link", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?m)^\s{0,3}(#{1,6}|>|[-*+]|\d+\.)\s+"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[*_`~|]"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The complete sentences of `text` after the first `spoken` characters, and how far that
    /// reaches. While a reply is still being written only finished sentences go; when it's
    /// done (`final`), the rest too. Code blocks still open aren't split.
    public static func nextChunks(in text: String, after spoken: Int, final: Bool) -> (chunks: [String], spoken: Int) {
        let characters = Array(text)
        guard spoken < characters.count else { return ([], spoken) }
        var chunks: [String] = []
        var start = spoken
        var index = spoken
        var inCode = characters[..<spoken].count >= 3 && String(characters[..<spoken]).components(separatedBy: "```").count % 2 == 0
        while index < characters.count {
            if index + 2 < characters.count, characters[index] == "`", characters[index + 1] == "`", characters[index + 2] == "`" {
                inCode.toggle()
                index += 3
                continue
            }
            let char = characters[index]
            let next: Character? = index + 1 < characters.count ? characters[index + 1] : nil
            let endsSentence = !inCode && ((".!?…".contains(char) && (next?.isWhitespace ?? false)) || char == "\n")
            if endsSentence {
                let piece = clean(String(characters[start...index]))
                if !piece.isEmpty { chunks.append(piece) }
                start = index + 1
            }
            index += 1
        }
        if final, start < characters.count {
            let piece = clean(String(characters[start...]))
            if !piece.isEmpty { chunks.append(piece) }
            start = characters.count
        }
        return (chunks, start)
    }
}

/// Speaks replies with an iPhone voice, sentence by sentence as they arrive.
@MainActor
public final class ReplySpeaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    /// The message being spoken.
    @Published public private(set) var speakingId: String?

    private let synthesizer = AVSpeechSynthesizer()
    private var spoken: [String: Int] = [:]
    /// Sentences handed to the synthesizer and not finished yet.
    private var queued: Set<ObjectIdentifier> = []
    private var pending: Int { queued.count }
    private var finished: Set<String> = []
    private var voice: AVSpeechSynthesisVoice?
    private var rate: Float = AVSpeechUtteranceDefaultSpeechRate

    /// The call's own speaker (it speaks during a call; every other one stays quiet).
    public var belongsToCall = false
    private var callObserver: NSObjectProtocol?

    public override init() {
        super.init()
        synthesizer.delegate = self
        callObserver = NotificationCenter.default.addObserver(forName: AudioSessionOwner.callStarted, object: nil,
                                                              queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.belongsToCall else { return }
                self.stop()
            }
        }
    }

    /// The whole reply, from the start (the Listen button).
    public func speak(id: String, text: String, settings: AgentVoiceSettings) {
        stop()
        spoken[id] = 0          // from the start again, even if it was spoken before
        finished.remove(id)
        follow(id: id, text: text, final: true, settings: settings)
    }

    /// A reply as it's written: says each sentence once it's complete, the rest when `final`.
    public func follow(id: String, text: String, final: Bool, settings: AgentVoiceSettings) {
        guard belongsToCall || !AudioSessionOwner.handsFree else { return }
        if speakingId != id {
            guard speakingId == nil || !synthesizer.isSpeaking else {
                // Another reply is still being spoken: this one starts after it.
                if spoken[id] == nil { spoken[id] = 0 }
                return queueLater(id: id, text: text, final: final, settings: settings)
            }
            configure(settings)
            speakingId = id
            spoken[id] = spoken[id] ?? 0
        }
        let (chunks, reached) = SpeechText.nextChunks(in: text, after: spoken[id] ?? 0, final: final)
        spoken[id] = reached
        if final { finished.insert(id) }
        for chunk in chunks { say(chunk) }
        if pending == 0 && final { speakingId = nil }
    }

    private var later: [(id: String, text: String, final: Bool, settings: AgentVoiceSettings)] = []

    private func queueLater(id: String, text: String, final: Bool, settings: AgentVoiceSettings) {
        later.removeAll { $0.id == id }
        later.append((id, text, final, settings))
    }

    public func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        queued = []
        speakingId = nil
        later = []
    }

    private func configure(_ settings: AgentVoiceSettings) {
        voice = settings.voice.flatMap { AVSpeechSynthesisVoice(identifier: $0) }
            ?? AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        rate = Self.rate(settings.rate)
        #if os(iOS)
        if !AudioSessionOwner.handsFree {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try? AVAudioSession.sharedInstance().setActive(true)
        }
        #endif
    }

    /// 0…1 from the settings to the synthesizer's range (0.5 = normal).
    static func rate(_ value: Double) -> Float {
        let low = AVSpeechUtteranceMinimumSpeechRate, high = AVSpeechUtteranceMaximumSpeechRate
        let normal = AVSpeechUtteranceDefaultSpeechRate
        let v = Float(min(max(value, 0), 1))
        return v <= 0.5 ? low + (normal - low) * (v / 0.5) : normal + (high - normal) * ((v - 0.5) / 0.5) * 0.6
    }

    private func say(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = rate
        queued.insert(ObjectIdentifier(utterance))
        synthesizer.speak(utterance)
    }

    /// A sample for the voice picker.
    public func preview(voice identifier: String?, rate value: Double, text: String) {
        stop()
        configure(AgentVoiceSettings(voice: identifier, rate: value))
        say(text)
        speakingId = "preview"
    }

    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        Task { @MainActor in self.utteranceEnded(key) }
    }

    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        Task { @MainActor in self.queued.remove(key) }  // a stopped one; only ever removes its own
    }

    private func utteranceEnded(_ key: ObjectIdentifier) {
        guard queued.remove(key) != nil else { return }  // from before a stop
        guard pending == 0, let id = speakingId else { return }
        guard finished.contains(id) || id == "preview" else { return }  // more of this reply is coming
        speakingId = nil
        if !later.isEmpty {
            let next = later.removeFirst()
            follow(id: next.id, text: next.text, final: next.final, settings: next.settings)
        }
    }
}
