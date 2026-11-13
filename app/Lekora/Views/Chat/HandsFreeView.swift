import SwiftUI

/// Hands-free conversation, full screen like a call (docs/voice.md §3): the agent's face,
/// whether it's listening, thinking or speaking, what was last said, plain or personality
/// voice, and Mute / End. Keeps going with the screen locked.
struct HandsFreeView: View {
    @ObservedObject var gateway: GatewayClient
    let agentName: String
    @StateObject private var session: HandsFreeSession
    @Environment(\.dismiss) private var dismiss

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
        switch session.phase {
        case .starting: return "Starting…"
        case .listening: return session.muted ? "Muted" : "Listening…"
        case .hearing: return "Listening…"
        case .thinking: return "Thinking…"
        case .speaking: return "Speaking… talk to interrupt"
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

                if gateway.hermesVoice[profileId]?.available == true {
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

                Spacer()

                ZStack {
                    ForEach(0..<3, id: \.self) { ring in
                        Circle()
                            .stroke(tint.opacity(0.35 - Double(ring) * 0.1), lineWidth: 2)
                            .frame(width: 180 + CGFloat(ring) * 36, height: 180 + CGFloat(ring) * 36)
                            .scaleEffect(ringScale(ring))
                            .animation(.easeOut(duration: 0.12), value: session.level)
                    }
                    LKAgentAvatar(id: profileId, palette: gateway.avatarPalettes[profileId], size: 150,
                                  working: session.phase == .thinking || session.phase == .speaking)
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

                Text(session.caption)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(4)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, LK.Spacing.xl)
                    .frame(minHeight: 80, alignment: .top)

                Spacer()

                HStack(spacing: 56) {
                    callButton(session.muted ? "mic.slash.fill" : "mic.fill",
                               label: session.muted ? "Unmute" : "Mute",
                               fill: session.muted ? .white : .white.opacity(0.18),
                               glyph: session.muted ? .black : .white) {
                        session.muted.toggle()
                    }
                    callButton("phone.down.fill", label: "End", fill: LK.Palette.danger, glyph: .white) {
                        dismiss()
                    }
                }
                .padding(.bottom, LK.Spacing.xl)
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: session.phase)
        .task { await session.start() }
        .onDisappear { session.end() }
    }

    private func ringScale(_ ring: Int) -> CGFloat {
        switch session.phase {
        case .listening, .hearing:
            return 1 + CGFloat(session.muted ? 0 : session.level) * (0.25 + CGFloat(ring) * 0.1)
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
