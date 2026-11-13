import SwiftUI

/// Chat Settings › Voice › Direct Voice (docs/voice.md §4): where the agent's voice comes from
/// when Lekora talks to the voice service itself, streaming the sound while it's made. Saved on
/// the Hermes instance; a key typed here is kept there and never shown again.
struct DirectVoiceView: View {
    @ObservedObject var gateway: GatewayClient
    let profileId: String
    let agentName: String

    @State private var info: DirectVoiceInfo?
    @State private var settings: DirectVoiceSettings?
    @State private var newKey = ""
    @State private var saving = false
    @State private var testing = false
    @State private var failure: String?
    @State private var saved = false
    @StateObject private var player = VoicePlayer()

    private var source: String { settings?.source ?? "auto" }
    private var provider: String? { ["fish", "elevenlabs", "openai"].contains(source) ? source : nil }

    private static let labels = ["fish": "Fish Audio", "elevenlabs": "ElevenLabs", "openai": "OpenAI-compatible"]

    var body: some View {
        Form {
            if let settings {
                Section {
                    Picker("Voice From", selection: binding(\.source)) {
                        Text("Automatic").tag("auto")
                        Text("Fish Audio").tag("fish")
                        Text("ElevenLabs").tag("elevenlabs")
                        Text("OpenAI-compatible").tag("openai")
                        Text("Off").tag("off")
                    }
                } footer: {
                    Text(sourceExplanation(settings))
                }

                switch source {
                case "fish":
                    Section {
                        field("Voice ID", text: binding(\.fish.voice_id), prompt: "From the voice's page on fish.audio")
                        field("Model", text: binding(\.fish.model), prompt: "s2.1-pro")
                        LabeledContent("Speed") {
                            Stepper(String(format: "%.2f×", settings.fish.speed), value: binding(\.fish.speed), in: 0.5...2, step: 0.05)
                        }
                    } header: { Text("Fish Audio") } footer: {
                        Text("The Voice ID is the long code in the voice's web address (fish.audio/m/…). Models: s2.1-pro, or drama-3 for acted [tags] like [laughs].")
                    }
                case "elevenlabs":
                    Section {
                        field("Voice ID", text: binding(\.elevenlabs.voice_id), prompt: "From ElevenLabs › Voices")
                        field("Model", text: binding(\.elevenlabs.model_id), prompt: "eleven_flash_v2_5")
                    } header: { Text("ElevenLabs") }
                case "openai":
                    Section {
                        field("Server", text: binding(\.openai.base_url), prompt: "https://api.openai.com/v1")
                        field("Model", text: binding(\.openai.model), prompt: "gpt-4o-mini-tts")
                        field("Voice", text: binding(\.openai.voice), prompt: "alloy")
                    } header: { Text("OpenAI-compatible") } footer: {
                        Text("Any service that speaks the OpenAI speech API (OpenAI, Kokoro, a local server…).")
                    }
                default:
                    EmptyView()
                }

                if let provider {
                    Section {
                        SecureField(keyPrompt(provider), text: $newKey)
                            .textContentType(.password)
                            .autocorrectionDisabled()
                        if info?.keys[provider] == "app" {
                            Button("Forget Saved Key", role: .destructive) { save(clearingKey: true) }
                        }
                    } header: { Text("Key") } footer: {
                        Text(keyExplanation(provider))
                    }
                }

                Section {
                    Button {
                        save()
                    } label: {
                        Label(saved ? "Saved" : "Save", systemImage: saved ? "checkmark" : "square.and.arrow.down")
                    }
                    .disabled(saving)
                    Button {
                        test()
                    } label: {
                        Label(testing ? "Making a sample…" : "Hear a Sample", systemImage: "play.circle")
                    }
                    .disabled(testing || saving || source == "off")
                } footer: {
                    Text("A sample is a few seconds of speech from the voice service, on its usual charges.")
                }
            } else if failure == nil {
                Section { ProgressView() }
            }
            if let failure {
                Section { LKNotice(.warning, failure) }
            }
        }
        .navigationTitle("Direct Voice")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
        .onDisappear { player.stop() }
    }

    private func binding<Value>(_ path: WritableKeyPath<DirectVoiceSettings, Value>) -> Binding<Value> {
        Binding(get: { settings![keyPath: path] }, set: { settings?[keyPath: path] = $0; saved = false })
    }

    private func field(_ title: String, text: Binding<String>, prompt: String) -> some View {
        LabeledContent(title) {
            TextField(title, text: text, prompt: Text(prompt))
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
        }
    }

    private func sourceExplanation(_ settings: DirectVoiceSettings) -> String {
        switch settings.source {
        case "auto":
            if let hermes = info?.hermes_streaming {
                return "\(agentName)'s Hermes voice, streamed by Hermes (\(hermes)). Nothing to set up."
            }
            return "\(agentName)'s Hermes voice can't be streamed (for example, a custom voice script), so replies are made a sentence at a time as before. Choose the service below to stream it."
        case "off":
            return "Replies are made a sentence at a time with \(agentName)'s Hermes voice, as before."
        default:
            return "Lekora connects to \(Self.labels[settings.source] ?? "the service") itself and streams the sound to your phone while it's made. If it fails, \(agentName)'s Hermes voice is used."
        }
    }

    private func keyPrompt(_ provider: String) -> String {
        switch info?.keys[provider] ?? "" {
        case "": return "Paste the API key"
        case "app": return "Saved (type to replace)"
        default: return "Using the instance's key (type to replace)"
        }
    }

    private func keyExplanation(_ provider: String) -> String {
        let origin = info?.keys[provider] ?? ""
        let name = Self.labels[provider] ?? provider
        switch origin {
        case "": return provider == "openai"
            ? "Optional for local servers. Kept on the Hermes instance, never on this phone."
            : "No \(name) key was found on the Hermes instance. Paste one; it's kept there, never on this phone."
        case "app": return "The key you saved here is in use. Forget it to use the instance's own key, if it has one."
        default: return "Using \(origin) from \(agentName)'s Hermes settings. Paste a different key to use that instead."
        }
    }

    private func load() async {
        do {
            let got = try await gateway.directVoice(for: profileId)
            info = got
            settings = got.settings
        } catch {
            failure = "Couldn't load this: \(error.localizedDescription). The Lekora plugin on the Hermes instance may need updating."
        }
    }

    private func save(clearingKey: Bool = false) {
        guard let settings else { return }
        saving = true
        failure = nil
        let typed = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty field leaves the saved key alone; "Forget Saved Key" clears it.
        let key = provider.flatMap { provider -> (provider: String, value: String)? in
            clearingKey ? (provider, "") : typed.isEmpty ? nil : (provider, typed)
        }
        Task {
            defer { saving = false }
            do {
                info = try await gateway.setDirectVoice(settings, key: key, for: profileId)
                self.settings = info?.settings
                newKey = ""
                saved = true
            } catch {
                failure = "Couldn't save: \(error.localizedDescription)"
            }
        }
    }

    private func test() {
        failure = nil
        testing = true
        Task {
            defer { testing = false }
            do {
                if let settings { info = try await gateway.setDirectVoice(settings, for: profileId) }
                let url = try await gateway.testDirectVoice(for: profileId)
                player.play(id: "direct-voice-sample", url: url, from: 0)
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
