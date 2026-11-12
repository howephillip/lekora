import SwiftUI
import AVFoundation

/// Names for voices (docs/voice.md §2).
enum LKVoiceNames {
    static func name(of identifier: String?) -> String {
        guard let identifier, let voice = AVSpeechSynthesisVoice(identifier: identifier) else { return "iPhone Default" }
        return voice.name
    }

    static func quality(_ voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        default: return "Standard"
        }
    }

    static func provider(_ id: String?) -> String {
        switch id ?? "" {
        case "elevenlabs": return "ElevenLabs"
        case "openai": return "OpenAI"
        case "gemini": return "Google Gemini"
        case "xai": return "xAI"
        case "mistral": return "Mistral"
        case "minimax": return "MiniMax"
        case "deepinfra": return "DeepInfra"
        case "fish", "fishaudio": return "Fish Audio"
        default:
            // A custom or plugin voice: its name as set up in Hermes, tidied ("fish_audio" -> "Fish Audio").
            guard let id, !id.isEmpty else { return "Hermes" }
            return id.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ").capitalized
        }
    }
}

/// Every iPhone voice for your language (or all languages), best first, each with a sample.
struct LKVoicePicker: View {
    let selected: String?
    let rate: Double
    let choose: (String?) -> Void
    @StateObject private var speaker = ReplySpeaker()
    @State private var allLanguages = false
    @State private var current: String?
    @State private var personalVoice = AVSpeechSynthesizer.personalVoiceAuthorizationStatus

    init(selected: String?, rate: Double, choose: @escaping (String?) -> Void) {
        self.selected = selected
        self.rate = rate
        self.choose = choose
        _current = State(initialValue: selected)
    }

    private var language: String {
        String(AVSpeechSynthesisVoice.currentLanguageCode().prefix(2))
    }

    private var voices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { allLanguages || $0.language.hasPrefix(language) }
            .filter { !$0.voiceTraits.contains(.isNoveltyVoice) }
            .sorted { ($0.quality.rawValue, $1.name) > ($1.quality.rawValue, $0.name) }
    }

    private func grouped() -> [(String, [AVSpeechSynthesisVoice])] {
        let personal = voices.filter { $0.voiceTraits.contains(.isPersonalVoice) }
        let others = voices.filter { !$0.voiceTraits.contains(.isPersonalVoice) }
        var groups: [(String, [AVSpeechSynthesisVoice])] = []
        if !personal.isEmpty { groups.append(("Personal Voice", personal)) }
        for quality in ["Premium", "Enhanced", "Standard"] {
            let list = others.filter { LKVoiceNames.quality($0) == quality }
            if !list.isEmpty { groups.append((quality, list)) }
        }
        return groups
    }

    var body: some View {
        List {
            Section {
                row(name: "iPhone Default", detail: "Your iPhone's spoken-content voice", id: nil)
                Toggle("All Languages", isOn: $allLanguages)
            } footer: {
                Text("Better voices can be downloaded in Settings › Accessibility › Read & Speak › Voices.")
            }
            if personalVoice == .notDetermined {
                Section {
                    Button("Use My Personal Voice…") {
                        AVSpeechSynthesizer.requestPersonalVoiceAuthorization { status in
                            Task { @MainActor in personalVoice = status }
                        }
                    }
                } footer: {
                    Text("If you've made a Personal Voice on this iPhone, your agents can speak with it.")
                }
            }
            ForEach(grouped(), id: \.0) { title, list in
                Section(title) {
                    ForEach(list, id: \.identifier) { voice in
                        row(name: voice.name, detail: Locale.current.localizedString(forIdentifier: voice.language) ?? voice.language,
                            id: voice.identifier)
                    }
                }
            }
        }
        .navigationTitle("Voice")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onDisappear { speaker.stop() }
    }

    private func row(name: String, detail: String, id: String?) -> some View {
        HStack {
            Button {
                current = id
                choose(id)
                speaker.preview(voice: id, rate: rate, text: "Hi, I'm \(name). This is how I'll sound.")
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name).foregroundStyle(.primary)
                        Text(detail).font(LK.Typography.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if current == id {
                        Image(systemName: "checkmark").foregroundStyle(LK.Palette.accent).fontWeight(.semibold)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                speaker.preview(voice: id, rate: rate, text: "Hi, I'm \(name). This is how I'll sound.")
            } label: {
                Image(systemName: "play.circle").font(.title3)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Hear \(name)")
        }
    }
}
