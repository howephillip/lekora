import SwiftUI

// The agents home and its pieces (docs/agents-home.md): avatars, list rows, times.

// MARK: - Avatar

/// An agent's avatar: a little visor bot of its own (head shape, eyes, ears, antenna and
/// colours all come from the agent's id with a stable hash, so it looks the same on every
/// phone). It's alive: it blinks, glances around, bobs, and its antenna wobbles; each agent
/// keeps its own rhythm, livelier while it works. Still with Reduce Motion on.
public struct LKAgentAvatar: View {
    private let id: String
    private let palette: Int?
    private let size: CGFloat
    private let working: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - id: the agent's profile id (decides its look and rhythm).
    ///   - palette: the colours given to it among the host's agents (`LKAgentLook.assignPalettes`),
    ///     so no two of your agents share colours; nil = from the id alone.
    ///   - working: livelier while the agent works.
    public init(id: String, palette: Int? = nil, size: CGFloat = 40, working: Bool = false) {
        self.id = id
        self.palette = palette
        self.size = size
        self.working = working
    }

    public var body: some View {
        let look = LKAgentLook(id: id, palette: palette)
        TimelineView(.animation(paused: reduceMotion)) { context in
            let motion = LKAgentMotion(look: look, working: working,
                                       time: reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate)
            LKBot(look: look, motion: motion, size: size)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The bot drawn at one moment of its animation.
private struct LKBot: View {
    let look: LKAgentLook
    let motion: LKAgentMotion
    let size: CGFloat

    private var headWidth: CGFloat { size * look.headShape.width }
    private var headHeight: CGFloat { size * look.headShape.height }

    var body: some View {
        ZStack {
            if look.hasAntenna { antenna }
            if look.hasEars { ears }
            head
                .overlay { visor }
        }
        .frame(width: size, height: size)
        .offset(y: size * (0.06 + motion.bob))
        .scaleEffect(x: 1 + motion.squash, y: 1 - motion.squash, anchor: .bottom)
        .rotationEffect(.degrees(motion.tilt), anchor: .bottom)
    }

    private var head: some View {
        look.headShape.shape(size: CGSize(width: headWidth, height: headHeight))
            .fill(LinearGradient(colors: [look.top, look.bottom], startPoint: .top, endPoint: .bottom))
            .overlay(alignment: .top) {
                // A soft shine on top of the head.
                Capsule()
                    .fill(.white.opacity(0.35))
                    .frame(width: headWidth * 0.34, height: headHeight * 0.07)
                    .offset(x: -headWidth * 0.14, y: headHeight * 0.07)
            }
            .frame(width: headWidth, height: headHeight)
    }

    private var visor: some View {
        let width = headWidth * 0.74
        let height = headHeight * 0.5
        return RoundedRectangle(cornerRadius: height * 0.42, style: .continuous)
            .fill(Color(white: 0.07))
            .overlay {
                HStack(spacing: width * 0.2) {
                    eye(visorHeight: height)
                    eye(visorHeight: height)
                }
                .offset(x: motion.look * width * 0.13, y: motion.lookUp * height * 0.08)
            }
            .frame(width: width, height: height)
            .offset(y: headHeight * 0.02)
    }

    private func eye(visorHeight: CGFloat) -> some View {
        let glow = look.eyeColor
        let shape: AnyShape
        let frame: CGSize
        switch look.eyeStyle {
        case .pill:
            shape = AnyShape(Capsule())
            frame = CGSize(width: visorHeight * 0.26, height: visorHeight * 0.5)
        case .round:
            shape = AnyShape(Circle())
            frame = CGSize(width: visorHeight * 0.38, height: visorHeight * 0.38)
        case .bar:
            shape = AnyShape(Capsule())
            frame = CGSize(width: visorHeight * 0.48, height: visorHeight * 0.26)
        }
        return shape
            .fill(glow)
            .frame(width: frame.width, height: frame.height)
            .scaleEffect(x: 1, y: motion.eyeOpen)
            .shadow(color: glow.opacity(0.9), radius: visorHeight * 0.12)
    }

    private var ears: some View {
        HStack(spacing: headWidth * 0.86) {
            Capsule().fill(look.bottom)
            Capsule().fill(look.bottom)
        }
        .frame(width: headWidth * 1.08, height: headHeight * 0.34)
        .offset(y: headHeight * 0.02)
    }

    private var antenna: some View {
        VStack(spacing: 0) {
            Circle()
                .fill(look.top)
                .frame(width: size * 0.13, height: size * 0.13)
                .shadow(color: look.eyeColor.opacity(motion.antennaGlow), radius: size * 0.06)
            Capsule()
                .fill(look.bottom)
                .frame(width: max(1.5, size * 0.04), height: size * 0.13)
        }
        .rotationEffect(.degrees(motion.antennaSwing), anchor: .bottom)
        .offset(y: -(headHeight / 2 + size * 0.1))
    }
}

/// Where a bot is in its animation at a moment. Pure, so it can be tested.
struct LKAgentMotion {
    var bob: CGFloat          // vertical offset, as a fraction of the size
    var squash: CGFloat       // 0 = none; >0 wider and shorter
    var tilt: Double          // degrees
    var look: CGFloat         // -1 left … 1 right
    var lookUp: CGFloat       // -1 up … 1 down
    var eyeOpen: CGFloat      // 1 open, ~0.1 closed (blinking)
    var antennaSwing: Double  // degrees
    var antennaGlow: Double   // 0…1

    /// Where the eyes rest, in turn: ahead, left, ahead, right, a glance up-left…
    private static let glances: [(CGFloat, CGFloat)] = [(0, 0), (-1, 0), (0, 0), (1, 0), (-0.6, -0.8),
                                                         (0, 0), (0.7, 0.3), (0, 0), (-1, 0.2), (1, -0.5)]

    init(look: LKAgentLook, working: Bool, time: TimeInterval) {
        let pace = working ? 2.2 : 1.0
        let t = time * pace + look.phase

        bob = CGFloat(sin(t * 2.0)) * (working ? 0.045 : 0.025)
        squash = CGFloat(max(0, -sin(t * 2.0))) * (working ? 0.05 : 0.025)  // a little squish at the bottom
        tilt = sin(t * 0.8) * (working ? 5 : 3)
        antennaSwing = sin(t * 2.0 - 0.8) * (working ? 16 : 9)
        antennaGlow = working ? 0.6 + 0.4 * (0.5 + 0.5 * sin(time * 6)) : 0.25

        // Glances: hold each for a moment, then move quickly to the next.
        let hold = working ? 0.9 : 2.3
        let step = (time + look.phase * 3) / hold
        let index = Int(floor(step))
        let progress = step - floor(step)
        let ease = Self.smoothstep(min(1, progress / (0.18 / hold * 2)))
        let seed = look.glanceSeed
        let from = Self.glances[(index - 1 + seed) %% Self.glances.count]
        let to = Self.glances[(index + seed) %% Self.glances.count]
        self.look = from.0 + (to.0 - from.0) * ease
        lookUp = from.1 + (to.1 - from.1) * ease

        // Blinks: one every few seconds (each agent its own rhythm), sometimes a double blink.
        let period = 3.4 + look.phase * 0.35
        let local = (time + look.phase * 5).truncatingRemainder(dividingBy: period)
        let blink = 0.16
        func closed(_ x: Double) -> CGFloat {
            guard x >= 0, x < blink else { return 1 }
            return CGFloat(max(0.1, abs(cos(x / blink * .pi))))
        }
        eyeOpen = min(closed(local), Int(time / period) % 3 == 0 ? closed(local - 0.28) : 1)
    }

    private static func smoothstep(_ x: Double) -> CGFloat {
        let c = min(max(x, 0), 1)
        return CGFloat(c * c * (3 - 2 * c))
    }
}

infix operator %% : MultiplicationPrecedence
/// Remainder that's never negative.
private func %% (a: Int, b: Int) -> Int { ((a % b) + b) % b }

/// An agent's look, picked from its id.
public struct LKAgentLook: Equatable {
    public enum HeadShape: CaseIterable, Equatable {
        case round, squircle, wide, dome

        var width: CGFloat { self == .wide ? 0.84 : 0.72 }
        var height: CGFloat {
            switch self {
            case .round: return 0.66
            case .squircle: return 0.64
            case .wide: return 0.56
            case .dome: return 0.66
            }
        }

        func shape(size: CGSize) -> AnyShape {
            switch self {
            case .round: return AnyShape(Ellipse())
            case .squircle: return AnyShape(RoundedRectangle(cornerRadius: size.height * 0.34, style: .continuous))
            case .wide: return AnyShape(Capsule())
            case .dome:
                return AnyShape(UnevenRoundedRectangle(topLeadingRadius: size.height * 0.5, bottomLeadingRadius: size.height * 0.22,
                                                       bottomTrailingRadius: size.height * 0.22, topTrailingRadius: size.height * 0.5,
                                                       style: .continuous))
            }
        }
    }

    public enum EyeStyle: CaseIterable, Equatable {
        case pill, round, bar
    }

    public let top: Color
    public let bottom: Color
    public let eyeColor: Color
    public let headShape: HeadShape
    public let eyeStyle: EyeStyle
    public let hasEars: Bool
    public let hasAntenna: Bool
    /// Where in its animation this agent starts, so agents don't move in step.
    public let phase: Double
    let glanceSeed: Int
    /// Index into the palette (for tests: spread across agents).
    public let paletteIndex: Int

    static let palette: [(Color, Color)] = [
        (Color(red: 1.00, green: 0.55, blue: 0.35), Color(red: 0.93, green: 0.27, blue: 0.47)),  // sunset
        (Color(red: 0.36, green: 0.80, blue: 0.98), Color(red: 0.25, green: 0.42, blue: 0.95)),  // sky
        (Color(red: 0.55, green: 0.90, blue: 0.45), Color(red: 0.10, green: 0.65, blue: 0.55)),  // lime to teal
        (Color(red: 0.80, green: 0.55, blue: 1.00), Color(red: 0.45, green: 0.30, blue: 0.95)),  // grape
        (Color(red: 1.00, green: 0.86, blue: 0.30), Color(red: 0.96, green: 0.64, blue: 0.05)),  // gold
        (Color(red: 1.00, green: 0.55, blue: 0.80), Color(red: 0.85, green: 0.30, blue: 0.85)),  // bubblegum
        (Color(red: 0.35, green: 0.90, blue: 0.85), Color(red: 0.15, green: 0.55, blue: 0.85)),  // lagoon
        (Color(red: 0.95, green: 0.40, blue: 0.35), Color(red: 0.70, green: 0.20, blue: 0.35)),  // cherry
    ]
    /// Eye glow per palette: a light that reads well on the dark visor.
    static let eyeColors: [Color] = [
        Color(red: 1.00, green: 0.85, blue: 0.55), Color(red: 0.55, green: 0.95, blue: 1.00),
        Color(red: 0.75, green: 1.00, blue: 0.60), Color(red: 0.90, green: 0.75, blue: 1.00),
        Color(red: 1.00, green: 0.95, blue: 0.55), Color(red: 1.00, green: 0.75, blue: 0.90),
        Color(red: 0.60, green: 1.00, blue: 0.95), Color(red: 1.00, green: 0.70, blue: 0.60),
    ]

    public init(id: String, palette: Int? = nil) {
        let hash = Self.stableHash(id)
        paletteIndex = palette.map { (($0 % Self.palette.count) + Self.palette.count) % Self.palette.count }
            ?? Int(hash % UInt64(Self.palette.count))
        (top, bottom) = Self.palette[paletteIndex]
        eyeColor = Self.eyeColors[paletteIndex]
        headShape = HeadShape.allCases[Int((hash / 8) % UInt64(HeadShape.allCases.count))]
        eyeStyle = EyeStyle.allCases[Int((hash / 32) % UInt64(EyeStyle.allCases.count))]
        hasEars = (hash / 96) % 2 == 0
        hasAntenna = (hash / 192) % 4 != 0          // most have one
        phase = Double((hash / 4096) % 628) / 100     // 0…2π
        glanceSeed = Int((hash / 1_000_000) % 10)
    }

    /// Colours for each of a host's agents, so no two share them (until there are more
    /// agents than colours). Same ids give the same result on every phone.
    /// - avoiding: colours already used by another computer's agents (docs/multiple-computers.md),
    ///   skipped while there are colours left.
    public static func assignPalettes(_ ids: [String], avoiding: Set<Int> = []) -> [String: Int] {
        var taken: Set<Int> = avoiding.count < palette.count ? avoiding : []
        var result: [String: Int] = [:]
        for id in Set(ids).sorted() {
            let preferred = Int(stableHash(id) % UInt64(palette.count))
            var choice = preferred
            if taken.count < palette.count {
                while taken.contains(choice) { choice = (choice + 1) % palette.count }
            }
            taken.insert(choice)
            result[id] = choice
        }
        return result
    }

    /// FNV-1a: the same number on every device and launch (Swift's hashValue isn't).
    static func stableHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}

// MARK: - Text and times

public enum LKChatText {
    /// A message as a one-glance preview: Markdown symbols removed, on one line.
    public static func preview(_ text: String) -> String {
        var plain = text
        // Headings read as a lead-in: "## Report" -> "Report:"
        plain = plain.replacingOccurrences(of: #"(?m)^\s{0,3}#{1,6}\s+(.+?)[\s#:]*$"#, with: "$1:", options: .regularExpression)
        // [label](link) -> label
        plain = plain.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        // Quotes and list markers at the start of lines.
        plain = plain.replacingOccurrences(of: #"(?m)^\s{0,3}(>\s?|[-*+]\s+|\d+\.\s+)"#, with: "", options: .regularExpression)
        // Emphasis and code marks.
        plain = plain.replacingOccurrences(of: #"(\*\*|__|\*|_|~~|`{1,3})"#, with: "", options: .regularExpression)
        return plain.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

public enum LKTime {
    /// For the agents list: "4:42 PM", "Yesterday", "Monday", "Oct 3, 2025".
    public static func listLabel(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(date) || isYesterday(date, now: now, calendar: calendar) {
            return "Yesterday"
        }
        let startOfToday = calendar.startOfDay(for: now)
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: startOfToday), date >= weekAgo {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    /// For the time line in a chat: "Today 4:42 PM", "Yesterday 9:10 AM", "Mon 9:10 AM", "Oct 3, 9:10 AM".
    public static func separatorLabel(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "Today \(time)" }
        if isYesterday(date, now: now, calendar: calendar) { return "Yesterday \(time)" }
        let startOfToday = calendar.startOfDay(for: now)
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: startOfToday), date >= weekAgo {
            return "\(date.formatted(.dateTime.weekday(.abbreviated))) \(time)"
        }
        return "\(date.formatted(.dateTime.month(.abbreviated).day())), \(time)"
    }

    /// Messages that get a time line above them: the first with a time, and any message
    /// more than `gap` after the one before (as in Messages).
    public static func separatorIds(for entries: [ChatEntry], gap: TimeInterval = 15 * 60) -> Set<String> {
        var ids: Set<String> = []
        var previous: Date?
        for entry in entries {
            guard let date = entry.date else { continue }
            if previous == nil || date.timeIntervalSince(previous!) > gap {
                ids.insert(entry.id)
            }
            previous = date
        }
        return ids
    }

    private static func isYesterday(_ date: Date, now: Date, calendar: Calendar) -> Bool {
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now) else { return false }
        return calendar.isDate(date, inSameDayAs: yesterday)
    }
}

/// The small centered time line between messages.
public struct LKTimeSeparator: View {
    private let date: Date

    public init(_ date: Date) {
        self.date = date
    }

    public var body: some View {
        Text(LKTime.separatorLabel(date))
            .font(LK.Typography.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.top, LK.Spacing.sm)
    }
}

// MARK: - List row

/// One agent in the agents list, laid out like a conversation in Messages.
public struct LKAgentRow: View {
    public struct Content: Equatable {
        public var id: String
        public var palette: Int?
        public var name: String
        public var preview: String
        public var date: Date?
        public var unread: Bool
        /// What it's doing right now, when working ("Searching the web…").
        public var working: String?
        /// What it needs from you ("Needs your approval"), shown above everything else.
        public var attention: String?
        /// The computer it's on, shown after the name once there are several (docs/multiple-computers.md).
        public var computer: String?

        public init(id: String, palette: Int? = nil, name: String, preview: String, date: Date?,
                    unread: Bool, working: String?, attention: String? = nil, computer: String? = nil) {
            self.attention = attention
            self.computer = computer
            self.id = id
            self.palette = palette
            self.name = name
            self.preview = preview
            self.date = date
            self.unread = unread
            self.working = working
        }
    }

    private let content: Content

    public init(_ content: Content) {
        self.content = content
    }

    public var body: some View {
        HStack(alignment: .center, spacing: LK.Spacing.md) {
            Circle()
                .fill(content.unread ? LK.Palette.accent : .clear)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            LKAgentAvatar(id: content.id, palette: content.palette, size: 52, working: content.working != nil)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(content.name)
                        .font(LK.Typography.headline.weight(content.unread ? .bold : .semibold))
                        .lineLimit(1)
                        .layoutPriority(1)
                    if let computer = content.computer {
                        Text("· \(computer)")
                            .font(LK.Typography.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: LK.Spacing.sm)
                    if let date = content.date {
                        Text(LKTime.listLabel(date))
                            .font(LK.Typography.footnote)
                            .foregroundStyle(content.unread ? LK.Palette.accent : .secondary)
                    }
                }
                if let attention = content.attention {
                    // Same height as a two-line preview; the label sits on the first line.
                    ZStack(alignment: .topLeading) {
                        Text("\n")
                            .lineLimit(2, reservesSpace: true)
                            .opacity(0)
                            .accessibilityHidden(true)
                        Label(attention, systemImage: "exclamationmark.circle.fill")
                            .fontWeight(.semibold)
                            .foregroundStyle(LK.Palette.warning)
                            .lineLimit(1)
                    }
                    .font(LK.Typography.subheadline)
                } else if let working = content.working {
                    // Same height as a two-line preview, so the list doesn't shift.
                    ZStack(alignment: .topLeading) {
                        Text("\n")
                            .lineLimit(2, reservesSpace: true)
                            .opacity(0)
                            .accessibilityHidden(true)
                        HStack(spacing: LK.Spacing.sm) {
                            LKTypingDots()
                            Text(working)
                                .lineLimit(1)
                        }
                        .foregroundStyle(.secondary)
                    }
                    .font(LK.Typography.subheadline)
                } else {
                    Text(content.preview)
                        .font(LK.Typography.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2, reservesSpace: true)
                }
            }
        }
        .padding(.vertical, LK.Spacing.xs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(content.unread ? "New messages" : "")
    }
}

#Preview("Agent bots") {
    let ids = ["default", "ashlyn", "brenda", "bruce", "carl", "diane", "work", "coder"]
    let palettes = LKAgentLook.assignPalettes(ids)
    VStack(spacing: 24) {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 24) {
            ForEach(ids, id: \.self) { id in
                VStack {
                    LKAgentAvatar(id: id, palette: palettes[id], size: 64)
                    Text(id).font(.caption)
                }
            }
        }
        HStack(spacing: 16) {
            ForEach(ids.prefix(4), id: \.self) { id in
                LKAgentAvatar(id: id, palette: palettes[id], size: 28)
            }
        }
    }
    .padding()
    .preferredColorScheme(.dark)
}
