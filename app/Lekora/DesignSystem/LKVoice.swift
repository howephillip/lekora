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

/// Shown in place of the text box while recording: red dot, time, live waveform, and the hint
/// to slide left to cancel (red when letting go would cancel).
public struct LKRecordingBar: View {
    private let elapsed: TimeInterval
    private let levels: [Double]
    private let cancelling: Bool

    public init(elapsed: TimeInterval, levels: [Double], cancelling: Bool) {
        self.elapsed = elapsed
        self.levels = levels
        self.cancelling = cancelling
    }

    public var body: some View {
        HStack(spacing: LK.Spacing.sm) {
            Circle().fill(LK.Palette.danger).frame(width: 9, height: 9)
                .symbolEffect(.pulse)
            Text(LKVoiceText.duration(elapsed))
                .font(LK.Typography.callout.monospacedDigit())
            LKWaveform(levels, progress: 1, color: cancelling ? LK.Palette.danger : LK.Palette.accent)
                .frame(height: 22)
            Text(cancelling ? "Release to cancel" : "‹ Slide to cancel")
                .font(LK.Typography.caption)
                .foregroundStyle(cancelling ? LK.Palette.danger : .secondary)
                .fixedSize()
        }
        .padding(.horizontal, LK.Spacing.md)
        .frame(minHeight: 38)
        .glassEffect(.regular, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(cancelling ? "Recording. Release to cancel" : "Recording, \(LKVoiceText.duration(elapsed))")
    }
}

/// The mic: hold to record, let go to send, slide left to cancel. Reports the gesture; the
/// chat screen does the recording.
public struct LKMicButton: View {
    private let isRecording: Bool
    private let onStart: () -> Void
    private let onSlide: (Bool) -> Void
    private let onEnd: (Bool) -> Void
    @State private var pressing = false
    @State private var cancelled = false

    public static let cancelDistance: CGFloat = 90

    /// - Parameters:
    ///   - onSlide: true while far enough left that letting go cancels.
    ///   - onEnd: true = send, false = cancel.
    public init(isRecording: Bool, onStart: @escaping () -> Void, onSlide: @escaping (Bool) -> Void,
                onEnd: @escaping (Bool) -> Void) {
        self.isRecording = isRecording
        self.onStart = onStart
        self.onSlide = onSlide
        self.onEnd = onEnd
    }

    public var body: some View {
        Image(systemName: isRecording ? "mic.fill" : "mic")
            .font(.system(size: 18, weight: .semibold))
            .frame(width: 44, height: 44)  // the same size as Send
            .foregroundStyle(isRecording ? LK.Palette.onAccent : LK.Palette.accent)
            .background(isRecording ? AnyShapeStyle(LK.Palette.danger) : AnyShapeStyle(.clear), in: Circle())
            .scaleEffect(isRecording ? 1.25 : 1)
            .animation(.spring(duration: 0.25), value: isRecording)
            .glassEffect(.regular.interactive(), in: Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if !pressing {
                        pressing = true
                        cancelled = false
                        onStart()
                    }
                    let far = value.translation.width < -Self.cancelDistance
                    if far != cancelled {
                        cancelled = far
                        onSlide(far)
                    }
                }
                .onEnded { value in
                    pressing = false
                    onEnd(value.translation.width >= -Self.cancelDistance)
                })
            .accessibilityLabel("Record voice note")
            .accessibilityHint("Hold to record, release to send")
            .accessibilityAddTraits(.isButton)
    }
}
