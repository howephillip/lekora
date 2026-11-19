import SwiftUI

// The Helpers card (docs/delegation.md): the helpers an agent used for one reply, as a live
// tree. Content, so a solid surface like the other cards; the buttons are the system's.

public struct LKHelpersCard: View {
    private let tree: HelpersTree
    private let agentName: String
    private let nameFor: (String) -> String
    private let stop: ((String?) async throws -> Void)?

    @State private var opened: HelpersTree.Helper?
    @State private var stopping: Set<String> = []
    @State private var failure: String?

    /// - Parameters:
    ///   - nameFor: another agent's name from its profile id.
    ///   - stop: stops one helper (its id) or, with nil, all of them; nil = can't stop.
    public init(_ tree: HelpersTree, agentName: String, nameFor: @escaping (String) -> String,
                stop: ((String?) async throws -> Void)?) {
        self.tree = tree
        self.agentName = agentName
        self.nameFor = nameFor
        self.stop = stop
    }

    public var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: LK.Spacing.md) {
                header
                VStack(alignment: .leading, spacing: LK.Spacing.sm) {
                    ForEach(tree.rows) { row in
                        Button { opened = row.helper } label: {
                            LKHelperRow(helper: row.helper, depth: row.depth, nameFor: nameFor)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Shows what it was asked and what it reported")
                    }
                }
                if let failure {
                    Text(failure)
                        .font(LK.Typography.footnote)
                        .foregroundStyle(LK.Palette.danger)
                }
            }
            .padding(LK.Spacing.lg)
            .frame(maxWidth: 420, alignment: .leading)
            .background(LK.Surface.raised, in: RoundedRectangle(cornerRadius: LK.Radius.card, style: .continuous))
            Spacer(minLength: LK.Spacing.xl)
        }
        .sheet(item: $opened) { helper in
            LKHelperDetail(helper: current(helper), agentName: agentName, nameFor: nameFor,
                           stopping: stopping.contains(helper.id),
                           stop: stop == nil ? nil : { run(helper.id) })
                .presentationDetents([.medium, .large])
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: LK.Spacing.xxs) {
                Label("\(agentName)'s helpers", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(LK.Typography.headline)
                Text(LKHelpersText.summary(tree))
                    .font(LK.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: LK.Spacing.sm)
            if tree.workingCount > 0, stop != nil {
                Button(role: .destructive) { run(nil) } label: {
                    if stopping.contains("") {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(tree.workingCount == 1 ? "Stop" : "Stop All")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(stopping.contains(""))
            }
        }
    }

    /// The opened helper as it is now (the card keeps updating while its sheet is open).
    private func current(_ helper: HelpersTree.Helper) -> HelpersTree.Helper {
        tree.helpers.first { $0.id == helper.id } ?? helper
    }

    private func run(_ helperId: String?) {
        guard let stop else { return }
        let key = helperId ?? ""
        stopping.insert(key)
        failure = nil
        Task {
            do {
                try await stop(helperId)
            } catch {
                failure = error.localizedDescription
            }
            stopping.remove(key)
        }
    }
}

/// One helper in the tree: its state, what it was asked, and what it's doing.
struct LKHelperRow: View {
    let helper: HelpersTree.Helper
    let depth: Int
    let nameFor: (String) -> String

    var body: some View {
        HStack(alignment: .top, spacing: LK.Spacing.sm) {
            if depth > 0 {
                Image(systemName: "arrow.turn.down.right")
                    .font(LK.Typography.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, CGFloat(depth - 1) * LK.Spacing.lg)
                    .padding(.top, 3)
            }
            LKHelperStatusIcon(status: helper.status)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: LK.Spacing.xxs) {
                if let agent = helper.agent {
                    Text(nameFor(agent))
                        .font(LK.Typography.captionStrong)
                        .foregroundStyle(LK.Palette.accent)
                }
                Text(helper.goal)
                    .font(LK.Typography.subheadline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(LKHelpersText.detail(helper, now: context.date))
                        .font(LK.Typography.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(LK.Typography.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 3)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct LKHelperStatusIcon: View {
    let status: String

    var body: some View {
        switch status {
        case "working", "finishing":
            ProgressView().controlSize(.mini)
                .frame(width: 16, height: 16)
                .accessibilityLabel(status == "working" ? "Working" : "Finishing")
        case "done":
            icon("checkmark.circle.fill", LK.Palette.success, "Done")
        case "failed":
            icon("xmark.octagon.fill", LK.Palette.danger, "Failed")
        case "timed_out":
            icon("clock.badge.exclamationmark.fill", LK.Palette.warning, "Timed out")
        default:
            icon("stop.circle.fill", .secondary, "Stopped")
        }
    }

    private func icon(_ name: String, _ color: some ShapeStyle, _ label: String) -> some View {
        Image(systemName: name)
            .foregroundStyle(color)
            .frame(width: 16, height: 16)
            .accessibilityLabel(label)
    }
}

/// A helper opened from the card: its whole task and what it reported back.
struct LKHelperDetail: View {
    let helper: HelpersTree.Helper
    let agentName: String
    let nameFor: (String) -> String
    let stopping: Bool
    let stop: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LK.Spacing.lg) {
                    HStack(spacing: LK.Spacing.sm) {
                        LKHelperStatusIcon(status: helper.status)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(LKHelpersText.detail(helper, now: context.date))
                                .font(LK.Typography.subheadline)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    section("Asked to") { Text(helper.goal).textSelection(.enabled) }
                    if let summary = helper.summary, !summary.isEmpty {
                        section("Reported back") {
                            Text(LKMessageBubble.markdown(summary)).textSelection(.enabled)
                        }
                    } else if !helper.isWorking {
                        Text("It didn't report anything back.")
                            .font(LK.Typography.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if helper.isWorking, let stop {
                        Button(role: .destructive, action: stop) {
                            if stopping { ProgressView() } else { Label("Stop This Helper", systemImage: "stop.fill") }
                        }
                        .buttonStyle(.bordered)
                        .disabled(stopping || helper.doing == "Stopping")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(LK.Spacing.lg)
            }
            .navigationTitle(helper.agent.map(nameFor) ?? "\(agentName)'s helper")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: LK.Spacing.xs) {
            Text(title)
                .font(LK.Typography.captionStrong)
                .foregroundStyle(.secondary)
            content()
                .font(LK.Typography.body)
        }
    }
}

/// The card's words, kept apart so tests can check them.
public enum LKHelpersText {
    public static func summary(_ tree: HelpersTree) -> String {
        let n = tree.helpers.count
        let working = tree.workingCount
        if working == 0 {
            let failed = tree.helpers.filter { $0.status == "failed" || $0.status == "timed_out" }.count
            let base = n == 1 ? "1 helper finished" : "\(n) helpers finished"
            return failed > 0 ? "\(base), \(failed) didn't make it" : base
        }
        return n == 1 ? "1 helper working" : "\(working) of \(n) working"
    }

    public static func detail(_ helper: HelpersTree.Helper, now: Date) -> String {
        var parts: [String] = []
        switch helper.status {
        case "working": parts.append(helper.doing ?? "Starting")
        case "finishing": parts.append("Finishing")
        case "done": parts.append("Done")
        case "failed": parts.append("Failed")
        case "timed_out": parts.append("Timed out")
        default: parts.append("Stopped")
        }
        if helper.steps > 0 { parts.append(helper.steps == 1 ? "1 step" : "\(helper.steps) steps") }
        if let start = helper.startedDate {
            let end = helper.isWorking ? now : (helper.endedDate ?? now)
            parts.append(elapsed(max(0, end.timeIntervalSince(start))))
        }
        return parts.joined(separator: " · ")
    }

    public static func elapsed(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.down))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \(s % 3600 / 60)m"
    }
}

#Preview("Helpers") {
    let now = Date()
    func at(_ ago: TimeInterval) -> String { (now - ago).formatted(.iso8601) }
    let tree = HelpersTree(status: "working", helpers: [
        .init(id: "sa-0", goal: "Find three direct flights from Sydney to Tokyo in March under $900",
              status: "working", doing: "Web search", steps: 6, started_at: at(83)),
        .init(id: "sa-1", goal: "Compare hotels near Shinjuku station", status: "done", steps: 11,
              started_at: at(120), ended_at: at(20), summary: "Three good options: **Hotel Gracery**…"),
        .init(id: "sa-1a", parent: "sa-1", goal: "Check reviews for Hotel Gracery", status: "done", steps: 3,
              started_at: at(100), ended_at: at(60)),
        .init(id: "sa-2", goal: "Review the itinerary for visa issues", agent: "researcher",
              status: "working", doing: "Read file", steps: 2, started_at: at(30)),
        .init(id: "sa-3", goal: "Book a restaurant", status: "failed", steps: 1, started_at: at(50), ended_at: at(45)),
    ])
    return ScrollView {
        LKHelpersCard(tree, agentName: "Assistant", nameFor: { $0.capitalized }, stop: { _ in })
            .padding()
    }
}
