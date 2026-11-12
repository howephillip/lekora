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

    public init(_ voice: VoiceDetails, fromUser: Bool, transcript: String?, isPlaying: Bool, progress: Double,
                loading: Bool = false, onToggle: @escaping () -> Void, onSeek: @escaping (Double) -> Void) {
        self.voice = voice
        self.fromUser = fromUser
        self.transcript = transcript
        self.isPlaying = isPlaying
        self.progress = progress
        self.loading = loading
        self.onToggle = onToggle
        self.onSeek = onSeek
    }

    private var foreground: Color { fromUser ? LK.Palette.onAccent : LK.Palette.accent }

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
                        .accessibilityHidden(true)

                    Text(LKVoiceText.duration(isPlaying || progress > 0 ? voice.duration * (1 - progress) : voice.duration))
                        .font(LK.Typography.caption.monospacedDigit())
                        .foregroundStyle(fromUser ? LK.Palette.onAccent.opacity(0.85) : .secondary)
                        .frame(minWidth: 32, alignment: .trailing)
                }
                .padding(.horizontal, LK.Spacing.md)
                .padding(.vertical, LK.Spacing.sm)
                .background(fromUser ? LK.Surface.accent : LK.Surface.inset,
                            in: RoundedRectangle(cornerRadius: LK.Radius.bubble, style: .continuous))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Voice note, \(LKVoiceText.duration(voice.duration))")

                if let transcript, !transcript.isEmpty {
                    Text(transcript)
                        .font(LK.Typography.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(fromUser ? .trailing : .leading)
                        .textSelection(.enabled)
                        .frame(maxWidth: 260, alignment: fromUser ? .trailing : .leading)
                        .accessibilityLabel("Transcript: \(transcript)")
                }
            }
            if !fromUser { Spacer(minLength: LK.Size.bubbleSideMargin) }
        }
    }
}

/// The mic inside the message bar (a waveform, as in Messages): tap to start recording.
public struct LKFieldMicButton: View {
    private let action: () -> Void

    public init(action: @escaping () -> Void) {
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: "waveform")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Record voice note")
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

    public var body: some View {
        HStack(spacing: LK.Spacing.md) {
            LKWaveform(Self.padded(levels), progress: 1, color: LK.Palette.danger)
                .frame(height: 30)
                .accessibilityHidden(true)
            Text(LKVoiceText.duration(elapsed))
                .font(LK.Typography.body.monospacedDigit())
                .foregroundStyle(LK.Palette.danger)
            Button(action: onStop) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(LK.Palette.danger)
                    .frame(width: 14, height: 14)
                    .frame(width: 38, height: 38)
                    .background(LK.Palette.danger.opacity(0.25), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop recording")
        }
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

    public var body: some View {
        HStack(spacing: LK.Spacing.sm) {
            Button(action: onDiscard) {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 30, height: 30)  // the same size as the + it replaces
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
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

                if busy {
                    ProgressView().frame(width: 32, height: 32)
                } else {
                    LKSendArrow(action: onSend)
                }
            }
            .padding(.leading, LK.Spacing.xs + 2)
            .padding(.trailing, LK.Spacing.xs + 2)
            .frame(height: 50)  // the same height as while recording: the chat doesn't shift
            .glassEffect(LK.Glass.control, in: Capsule())
        }
    }
}
