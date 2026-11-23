import SwiftUI

/// Hands-free conversation, full screen like a call (docs/voice.md §3): the agent's face,
/// whether it's listening, thinking or speaking, plain or personality voice, and Mute / End.
/// What was said lives in the chat history, not on this screen. Keeps going with the screen locked.
struct HandsFreeView: View {
    @ObservedObject var gateway: GatewayClient
    let agentName: String
    @StateObject private var session: HandsFreeSession
    @Environment(\.dismiss) private var dismiss
    @State private var choosingModel = false
    @State private var callModel: CallModelData?
    /// Live voice engines (docs/live-calls.md): the one chosen is kept per agent until changed.
    @State private var engines: LiveEngines?
    @State private var live: LiveCallSession?
    @State private var engine = "agent"

    private var phase: HandsFreeSession.Phase { live?.phase ?? session.phase }
    private var level: Double { live?.level ?? session.level }
    private var isMuted: Bool { live?.muted ?? session.muted }

    init(gateway: GatewayClient, agentName: String) {
        self.gateway = gateway
        self.agentName = agentName
        _session = StateObject(wrappedValue: HandsFreeSession(gateway: gateway))
    }

    private var profileId: String { gateway.activeProfileId }
    private var voice: AgentVoiceSettings { gateway.voiceSettings[profileId] ?? .standard }
    private var personality: Bool { voice.style == "personality" }
    private var tint: Color { personality ? LKVoiceBubble.personalityColor : LK.Palette.accent }

    private var status: String {
        switch phase {
        case .starting: return "Starting…"
        case .listening: return isMuted ? "Muted" : "Listening…"
        case .hearing: return "Listening…"
        case .thinking:
            // What the agent is doing, as Hermes says it ("Searching the web…"; owner, 2026-11-22).
            if let doing = gateway.agentActivity[profileId]?.status, !doing.isEmpty { return doing }
            return "Thinking…"
        case .speaking: return live == nil ? "Speaking… talk to interrupt" : "Speaking…"
        case .failed(let reason): return reason
        }
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [tint.opacity(0.35), Color.black], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: LK.Spacing.xl) {
                Text(agentName)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.top, LK.Spacing.xl)

                engineMenu

                if engine == "agent", gateway.hermesVoice[profileId]?.available == true {
                    Picker("Voice", selection: Binding(get: { voice.style }, set: { style in
                        var updated = voice
                        updated.style = style
                        Task { try? await gateway.setVoiceSettings(updated, for: profileId) }
                    })) {
                        Text("Voice").tag("tts")
                        Text("Personality").tag("personality")
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 260)
                    .accessibilityLabel("Voice style")
                }

                if engine == "agent" {
                Button {
                    choosingModel = true
                } label: {
                    Label(callModel?.model.map { "Call model: \(LKCallModelSheet.short($0))" } ?? "Call model: main model",
                          systemImage: "bolt.fill")
                        .font(LK.Typography.caption)
                        .foregroundStyle(.white.opacity(0.75))
                }
                .accessibilityHint("The faster model this agent answers calls with")
                }

                Spacer()

                ZStack {
                    ForEach(0..<3, id: \.self) { ring in
                        Circle()
                            .stroke(tint.opacity(0.35 - Double(ring) * 0.1), lineWidth: 2)
                            .frame(width: 180 + CGFloat(ring) * 36, height: 180 + CGFloat(ring) * 36)
                            .scaleEffect(ringScale(ring))
                            .animation(.easeOut(duration: 0.12), value: level)
                    }
                    LKAgentAvatar(id: profileId, palette: gateway.avatarPalettes[profileId], size: 150,
                                  working: phase == .thinking || phase == .speaking)
                }
                .frame(height: 300)
                .accessibilityHidden(true)

                Text(status)
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.9))
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: status)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, LK.Spacing.xl)

                Spacer()

                HStack(spacing: 56) {
                    callButton(isMuted ? "mic.slash.fill" : "mic.fill",
                               label: isMuted ? "Unmute" : "Mute",
                               fill: isMuted ? .white : .white.opacity(0.18),
                               glyph: isMuted ? .black : .white) {
                        if let live { live.muted.toggle() } else { session.muted.toggle() }
                    }
                    callButton("phone.down.fill", label: "End", fill: LK.Palette.danger, glyph: .white) {
                        dismiss()
                    }
                }
                .padding(.bottom, LK.Spacing.xl)
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: phase)
        .sheet(isPresented: $choosingModel) {
            LKCallModelSheet(gateway: gateway, profileId: profileId, agentName: agentName, current: callModel) { callModel = $0 }
        }
        .task { callModel = try? await gateway.callModel(for: profileId) }
        .task {
            engines = try? await gateway.liveEngines(for: profileId)
            let chosen = engines?.engine ?? "agent"
            let usable = engines?.engines.first { $0.id == chosen }?.available ?? (chosen == "agent")
            await begin(usable ? chosen : "agent")
        }
        .onDisappear { stopCurrent() }
    }

    /// Engine: your agent's own voice, GPT-Live or Fish Live 3; kept for this agent until changed, and
    /// switchable during the call (owner, 2026-11-22).
    private var engineMenu: some View {
        Menu {
            ForEach(engines?.engines ?? []) { option in
                Button {
                    switchTo(option.id)
                } label: {
                    if option.id == engine { Label(option.name, systemImage: "checkmark") }
                    else { Text(option.available ? option.name : "\(option.name) — \(option.reason ?? "unavailable")") }
                }
                .disabled(!option.available)
            }
        } label: {
            Label(engines?.engines.first { $0.id == engine }?.name ?? "Your agent", systemImage: "waveform.circle")
                .font(LK.Typography.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.white.opacity(0.12), in: Capsule())
        }
        .accessibilityLabel("Call engine")
    }

    private func switchTo(_ id: String) {
        guard id != engine else { return }
        Task {
            if let updated = try? await gateway.setLiveEngine(id, for: profileId) { engines = updated }
            stopCurrent()
            await begin(id)
        }
    }

    private func begin(_ id: String) async {
        engine = id
        if id == "agent" {
            await session.start()
        } else {
            let call = LiveCallSession(gateway: gateway, profileId: profileId, engine: id)
            live = call
            await call.start()
        }
    }

    private func stopCurrent() {
        if let live {
            live.end()
            self.live = nil
        } else {
            session.end()
        }
    }

    private func ringScale(_ ring: Int) -> CGFloat {
        switch phase {
        case .listening, .hearing:
            return 1 + CGFloat(isMuted ? 0 : level) * (0.25 + CGFloat(ring) * 0.1)
        case .speaking:
            return 1.05 + CGFloat(ring) * 0.03
        default:
            return 1
        }
    }

    private func callButton(_ symbol: String, label: String, fill: Color, glyph: Color,
                            action: @escaping () -> Void) -> some View {
        VStack(spacing: LK.Spacing.xs) {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(glyph)
                    .frame(width: 72, height: 72)
                    .background(fill, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
            Text(label).font(.caption).foregroundStyle(.white.opacity(0.8))
        }
    }
}

/// The faster model an agent answers calls with (docs/voice.md §3, "Speed"): Hermes' own voice-chat
/// model, set per agent and kept until changed. The same agent, voice and tools; only calls use it.
struct LKCallModelSheet: View {
    @ObservedObject var gateway: GatewayClient
    let profileId: String
    let agentName: String
    let current: CallModelData?
    let changed: (CallModelData) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var models: [CatalogModel] = []
    @State private var failure: String?
    @State private var saving: String?

    static func short(_ model: String) -> String { model.split(separator: "/").last.map(String.init) ?? model }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Calls feel fast when the agent starts talking quickly. A quick model here answers words said in calls; typed chats keep \(agentName)'s main model. Same agent, same voice, same tools.")
                        .font(LK.Typography.footnote).foregroundStyle(.secondary)
                }
                if let failure { Text(failure).foregroundStyle(LK.Palette.danger) }
                Section {
                    row("Main model", detail: "Calls use the same model as chats", id: "") { save("", provider: "main") }
                    if let model = current?.model {
                        row(Self.short(model), detail: "Now: \(model)", id: model, selected: true) {}
                    }
                }
                Section("Quick picks") {
                    ForEach(quickPicks) { model in
                        row(model.name ?? model.id, detail: LKModelText.prices(input: model.input, output: model.output) ?? model.id,
                            id: model.id, selected: current?.model == model.id) { save(model.id, provider: "openrouter") }
                    }
                    if models.isEmpty && failure == nil { ProgressView() }
                }
                if !models.isEmpty {
                    Section {
                        NavigationLink("All OpenRouter models") {
                            LKOpenRouterBrowser(models: models, current: current?.model, switching: saving) { model in
                                save(model.id, provider: "openrouter")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Call Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task {
                do { models = try await gateway.modelCatalog(provider: "openrouter", in: profileId).models }
                catch { failure = "OpenRouter's list couldn't load: \(error.localizedDescription)" }
            }
        }
    }

    /// Fast, low-cost models that use tools: "flash", "mini", "haiku", "fast" in the name, cheapest first.
    private var quickPicks: [CatalogModel] {
        let words = ["flash", "haiku", "mini", "fast", "lite", "instant"]
        return models.filter { m in words.contains { (m.id + " " + (m.name ?? "")).lowercased().contains($0) } }
            .sorted { ($0.output ?? 99) < ($1.output ?? 99) }
            .prefix(8).map { $0 }
    }

    private func row(_ title: String, detail: String, id: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    Text(detail).font(LK.Typography.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if saving == id { ProgressView() }
                else if selected || (id.isEmpty && current?.model == nil) { Image(systemName: "checkmark").foregroundStyle(LK.Palette.accent) }
            }
        }
        .disabled(saving != nil)
    }

    private func save(_ model: String, provider: String) {
        saving = model
        Task {
            defer { saving = nil }
            do {
                let result = try await gateway.setCallModel(model, provider: provider, for: profileId)
                changed(result)
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
