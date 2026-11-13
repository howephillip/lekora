import SwiftUI

/// Voice notes in the chat, and the bar shown while recording one (docs/voice.md).
public enum LKVoiceText {
    /// "0:07", "1:23"
    public static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }
}

/// Waveform bars; the played part in full colour. Drag to pick a position (0…1).
public struct LKWaveform: View {
    private let levels: [Double]
    private let progress: Double
    private let color: Color
    private let onSeek: ((Double) -> Void)?

    public init(_ levels: [Double], progress: Double = 0, color: Color, onSeek: ((Double) -> Void)? = nil) {
        self.levels = levels.isEmpty ? Array(repeating: 0.15, count: 32) : levels
        self.progress = progress
        self.color = color
        self.onSeek = onSeek
    }

    public var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .center, spacing: 2) {
                ForEach(levels.indices, id: \.self) { index in
                    Capsule()
                        .fill(color.opacity(Double(index) / Double(levels.count) < progress ? 1 : 0.3))
                        .frame(height: max(3, geometry.size.height * levels[index]))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard let onSeek, geometry.size.width > 0 else { return }
                onSeek(min(max(value.location.x / geometry.size.width, 0), 1))
            })
        }
    }
}

/// A voice note: play/pause, waveform (drag to skip around), length; what Hermes heard
/// underneath in small print, like Messages.
public struct LKVoiceBubble: View {
    private let voice: VoiceDetails
    private let fromUser: Bool
    private let transcript: String?
    private let isPlaying: Bool
    private let progress: Double
    private let loading: Bool
    private let onToggle: () -> Void
    private let onSeek: (Double) -> Void
    /// A coloured note (personality voice replies are burnt orange), with light text.
    private let fill: Color?
    /// A small line under it (e.g. why its audio can't play).
    private let note: String?
    /// Still arriving: the waveform shimmers until there's sound.
    private let live: Bool
    /// What was written, when the voice said it differently (personality voice).
    private let written: String?
    @State private var expanded = false
    @State private var showsWritten = false

    public init(_ voice: VoiceDetails, fromUser: Bool, transcript: String?, isPlaying: Bool, progress: Double,
                loading: Bool = false, fill: Color? = nil, note: String? = nil, live: Bool = false,
                written: String? = nil,
                onToggle: @escaping () -> Void, onSeek: @escaping (Double) -> Void) {
        self.written = written
        self.fill = fill
        self.note = note
        self.live = live
        self.voice = voice
        self.fromUser = fromUser
        self.transcript = transcript
        self.isPlaying = isPlaying
        self.progress = progress
        self.loading = loading
        self.onToggle = onToggle
        self.onSeek = onSeek
    }

    private var foreground: Color { fromUser || fill != nil ? LK.Palette.onAccent : LK.Palette.accent }

    /// Personality voice replies (owner's choice: burnt orange).
    public static let personalityColor = Color(red: 0.80, green: 0.36, blue: 0.13)

    public var body: some View {
        HStack {
            if fromUser { Spacer(minLength: LK.Size.bubbleSideMargin) }
            VStack(alignment: fromUser ? .trailing : .leading, spacing: 3) {
                HStack(spacing: LK.Spacing.sm) {
                    Button(action: onToggle) {
                        ZStack {
                            if loading {
                                ProgressView().tint(foreground)
                            } else {
                                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 17, weight: .semibold))
                                    .contentTransition(.symbolEffect(.replace))
                            }
                        }
                        .frame(width: 30, height: 30)
                        .foregroundStyle(foreground)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isPlaying ? "Pause voice note" : "Play voice note")

                    LKWaveform(voice.waveform, progress: progress, color: foreground, onSeek: onSeek)
                        .frame(width: 150, height: 28)
                        .opacity(live && !isPlaying && progress == 0 ? 0.55 : 1)
                        .phaseAnimator(live && !isPlaying ? [0.6, 1.0] : [1.0]) { view, phase in
                            view.opacity(phase)
                        } animation: { _ in .easeInOut(duration: 0.7) }
                        .accessibilityHidden(true)

                    Text(LKVoiceText.duration(isPlaying || progress > 0 ? voice.duration * (1 - progress) : voice.duration))
                        .font(LK.Typography.caption.monospacedDigit())
                        .foregroundStyle(fromUser || fill != nil ? LK.Palette.onAccent.opacity(0.85) : .secondary)
                        .frame(minWidth: 32, alignment: .trailing)
                }
                .padding(.horizontal, LK.Spacing.md)
                .padding(.vertical, LK.Spacing.sm)
                .background(fromUser ? AnyShapeStyle(LK.Surface.accent) : fill.map { AnyShapeStyle($0) } ?? AnyShapeStyle(LK.Surface.inset),
                            in: RoundedRectangle(cornerRadius: LK.Radius.bubble, style: .continuous))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Voice note, \(LKVoiceText.duration(voice.duration))")

                if let note {
                    Label(note, systemImage: "exclamationmark.triangle.fill")
                        .font(LK.Typography.caption)
                        .foregroundStyle(LK.Palette.warning)
                        .frame(maxWidth: 260, alignment: fromUser ? .trailing : .leading)
                }
                if let transcript, !transcript.isEmpty {
                    transcriptView(transcript)
                }
            }
            if !fromUser { Spacer(minLength: LK.Size.bubbleSideMargin) }
        }
    }
}

/// The mic inside the message bar (a waveform, as in Messages). Hold it briefly to start
/// recording (a ring fills meanwhile), so a stray tap does nothing; then let go and talk.
public struct LKFieldMicButton: View {
    public static let holdDuration: Double = 0.5
    private let action: () -> Void
    @State private var fill: CGFloat = 0
    @State private var presses = 0

    public init(action: @escaping () -> Void) {
        self.action = action
    }

    public var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: fill)
                .stroke(LK.Palette.danger, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .opacity(fill > 0 ? 1 : 0)
            Image(systemName: "waveform")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(fill > 0 ? AnyShapeStyle(LK.Palette.danger) : AnyShapeStyle(.secondary))
                .scaleEffect(1 + 0.15 * fill)
        }
        .frame(width: 32, height: 32)
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: Self.holdDuration, maximumDistance: 40) {
            fill = 0
            action()
        } onPressingChanged: { pressing in
            if pressing { presses += 1 }
            withAnimation(pressing ? .linear(duration: Self.holdDuration) : .spring(duration: 0.25)) {
                fill = pressing ? 1 : 0
            }
        }
        .sensoryFeedback(.selection, trigger: presses)
        .accessibilityLabel("Record voice note")
        .accessibilityHint("Hold briefly to start recording")
        .accessibilityAction { action() }
    }
}

/// The whole message bar while recording: live red waveform, time, and the stop button.
/// No need to hold anything (as in Messages).
public struct LKRecordingBar: View {
    private let elapsed: TimeInterval
    private let levels: [Double]
    private let onStop: () -> Void

    public init(elapsed: TimeInterval, levels: [Double], onStop: @escaping () -> Void) {
        self.elapsed = elapsed
        self.levels = levels
        self.onStop = onStop
    }

    @State private var appeared = false

    public var body: some View {
        HStack(spacing: LK.Spacing.md) {
            LKWaveform(Self.padded(levels), progress: 1, color: LK.Palette.danger)
                .frame(height: 30)
                .scaleEffect(x: 1, y: appeared ? 1 : 0.2, anchor: .center)
                .animation(.easeOut(duration: 0.1), value: levels)
                .accessibilityHidden(true)
            Text(LKVoiceText.duration(elapsed))
                .font(LK.Typography.body.monospacedDigit())
                .foregroundStyle(LK.Palette.danger)
                .contentTransition(.numericText())
                .animation(.snappy, value: Int(elapsed))
            Button(action: onStop) {
                RoundedRectangle(cornerRadius: appeared ? 3 : 7, style: .continuous)
                    .fill(LK.Palette.danger)
                    .frame(width: 14, height: 14)
                    .frame(width: 38, height: 38)
                    .background(LK.Palette.danger.opacity(0.25), in: Circle())
                    .scaleEffect(appeared ? 1 : 0.4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop recording")
        }
        .onAppear { withAnimation(.spring(duration: 0.45, bounce: 0.35)) { appeared = true } }
        .padding(.leading, LK.Spacing.lg)
        .padding(.trailing, LK.Spacing.xs + 2)
        .frame(height: 50)
        .glassEffect(LK.Glass.control, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recording, \(LKVoiceText.duration(elapsed))")
    }

    /// The newest levels on the right, quiet bars before them while the recording is short.
    static func padded(_ levels: [Double], count: Int = 60) -> [Double] {
        let recent = Array(levels.suffix(count))
        return Array(repeating: 0.06, count: max(count - recent.count, 0)) + recent
    }
}

/// A recorded voice note waiting to go: × to throw it away; play it back, see how long it is,
/// "+" to record more onto the end, and Send (as in Messages).
public struct LKVoiceDraftBar: View {
    private let duration: TimeInterval
    private let waveform: [Double]
    private let isPlaying: Bool
    private let progress: Double
    private let busy: Bool
    private let onDiscard: () -> Void
    private let onToggle: () -> Void
    private let onSeek: (Double) -> Void
    private let onRecordMore: () -> Void
    private let onSend: () -> Void

    public init(duration: TimeInterval, waveform: [Double], isPlaying: Bool, progress: Double, busy: Bool = false,
                onDiscard: @escaping () -> Void, onToggle: @escaping () -> Void, onSeek: @escaping (Double) -> Void,
                onRecordMore: @escaping () -> Void, onSend: @escaping () -> Void) {
        self.duration = duration
        self.waveform = waveform
        self.isPlaying = isPlaying
        self.progress = progress
        self.busy = busy
        self.onDiscard = onDiscard
        self.onToggle = onToggle
        self.onSeek = onSeek
        self.onRecordMore = onRecordMore
        self.onSend = onSend
    }

    @State private var appeared = false

    public var body: some View {
        HStack(spacing: LK.Spacing.sm) {
            Button(action: onDiscard) {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 30, height: 30)  // the same size as the + it replaces
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .scaleEffect(appeared ? 1 : 0.3)
            .opacity(appeared ? 1 : 0)
            .offset(x: appeared ? 0 : 24)
            .accessibilityLabel("Delete voice note")

            HStack(spacing: LK.Spacing.sm) {
                Button(action: onToggle) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 34, height: 34)
                        .background(.quaternary, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPlaying ? "Pause" : "Play back")

                LKWaveform(waveform, progress: progress, color: .primary, onSeek: onSeek)
                    .frame(height: 24)
                    .scaleEffect(x: 1, y: appeared ? 1 : 0.2)
                    .opacity(appeared ? 1 : 0)
                    .animation(.linear(duration: 0.05), value: progress)
                    .accessibilityHidden(true)

                Button(action: onRecordMore) {
                    HStack(spacing: 3) {
                        Image(systemName: "plus").font(.system(size: 12, weight: .bold))
                        Text(LKVoiceText.duration(duration)).font(LK.Typography.subheadline.monospacedDigit())
                    }
                    .padding(.horizontal, LK.Spacing.sm + 2)
                    .frame(height: 30)
                    .background(.quaternary, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(busy)
                .accessibilityLabel("\(LKVoiceText.duration(duration)). Record more")

                Group {
                    if busy {
                        ProgressView().frame(width: 32, height: 32)
                    } else {
                        LKSendArrow(action: onSend)
                    }
                }
                .scaleEffect(appeared ? 1 : 0.3)
                .opacity(appeared ? 1 : 0)
            }
            .padding(.leading, LK.Spacing.xs + 2)
            .padding(.trailing, LK.Spacing.xs + 2)
            .frame(height: 50)  // the same height as while recording: the chat doesn't shift
            .glassEffect(LK.Glass.control, in: Capsule())
        }
        // The capsule settles from the recording bar; then its parts spring in, the × last.
        .onAppear { withAnimation(.spring(duration: 0.5, bounce: 0.3).delay(0.05)) { appeared = true } }
    }
}

/// Under an agent's reply: hear it (or stop). Small, like the actions under a reply in other chat apps.
public struct LKListenButton: View {
    private let speaking: Bool
    private let loading: Bool
    private let action: () -> Void

    public init(speaking: Bool, loading: Bool = false, action: @escaping () -> Void) {
        self.speaking = speaking
        self.loading = loading
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Group {
                if loading {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: speaking ? "stop.circle.fill" : "speaker.wave.2")
                        .symbolEffect(.variableColor.iterative, isActive: speaking)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(speaking ? LK.Palette.accent : .secondary)
            .frame(width: 30, height: 24, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(speaking ? "Stop speaking" : "Listen")
    }
}

extension LKVoiceBubble {
    /// What was said, in small print: two lines with a chevron to open it all (as in Messages);
    /// for personality voice, the written reply one tap further.
    @ViewBuilder
    func transcriptView(_ transcript: String) -> some View {
        let alignment: HorizontalAlignment = fromUser ? .trailing : .leading
        VStack(alignment: alignment, spacing: 4) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(transcript)
                        .lineLimit(expanded ? nil : 2)
                        .multilineTextAlignment(fromUser ? .trailing : .leading)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .font(LK.Typography.footnote)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Transcript: \(transcript)")
            .accessibilityHint(expanded ? "Shows less" : "Shows all of it")
            if expanded, let written, written != transcript {
                Button(showsWritten ? "Hide Written Reply" : "Show Written Reply") {
                    withAnimation(.snappy) { showsWritten.toggle() }
                }
                .font(LK.Typography.caption.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(LK.Palette.accent)
                if showsWritten {
                    Text(written)
                        .font(LK.Typography.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(LK.Spacing.sm)
                        .background(LK.Surface.inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
        .frame(maxWidth: 280, alignment: fromUser ? .trailing : .leading)
    }
}
