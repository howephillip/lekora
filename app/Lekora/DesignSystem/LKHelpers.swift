import SwiftUI

// The Delegated card (docs/delegation.md): work an agent handed to other agents (board tasks)
// or to sub-agent copies of itself, as a live tree. It only shows: the chat stays free, and
// results come back through the agent. Content, so a solid surface like the other cards.

public struct LKDelegationCard: View {
    private let tree: HelpersTree
    private let agentName: String
    private let nameFor: (String) -> String
    private let stop: ((String?) async throws -> Void)?
    private let taskView: ((_ board: String, _ task: String) -> AnyView)?

    @State private var opened: HelpersTree.Helper?
    @State private var stopping: Set<String> = []
    @State private var failure: String?

    /// - Parameters:
    ///   - nameFor: an agent's name from its profile id.
    ///   - stop: stops one piece of work (its id) or, with nil, all of it; nil = can't stop.
    ///   - taskView: a board task's page, for Open in Board; nil = not offered.
    public init(_ tree: HelpersTree, agentName: String, nameFor: @escaping (String) -> String,
                stop: ((String?) async throws -> Void)?,
                taskView: ((_ board: String, _ task: String) -> AnyView)? = nil) {
        self.tree = tree
        self.agentName = agentName
        self.nameFor = nameFor
        self.stop = stop
        self.taskView = taskView
    }

    public var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: LK.Spacing.md) {
                header
                VStack(alignment: .leading, spacing: LK.Spacing.sm) {
                    ForEach(tree.rows) { row in
                        Button { opened = row.helper } label: {
                            LKDelegationRow(helper: row.helper, depth: row.depth, nameFor: nameFor)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Shows the whole task and what came back")
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
            LKDelegationDetail(helper: current(helper), nameFor: nameFor, stopping: stopping.contains(helper.id),
                               stop: stop == nil ? nil : { run(helper.id) }, taskView: taskView)
                .presentationDetents([.medium, .large])
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: LK.Spacing.xxs) {
                Label("\(agentName) delegated", systemImage: "arrow.triangle.branch")
                    .font(LK.Typography.headline)
                Text(LKDelegationText.summary(tree))
                    .font(LK.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: LK.Spacing.sm)
            let stoppable = tree.helpers.filter(\.canStop).count
            if stoppable > 1, stop != nil {
                Button(role: .destructive) { run(nil) } label: {
                    if stopping.contains("") { ProgressView().controlSize(.small) } else { Text("Stop All") }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(stopping.contains(""))
            }
        }
    }

    /// The opened work as it is now (the card keeps updating while its sheet is open).
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

/// One piece of delegated work: who has it, the task, and where it's at.
struct LKDelegationRow: View {
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
            LKDelegationStatusIcon(status: helper.status)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: LK.Spacing.xxs) {
                Text(LKDelegationText.who(helper, nameFor: nameFor))
                    .font(LK.Typography.captionStrong)
                    .foregroundStyle(helper.agent != nil ? AnyShapeStyle(LK.Palette.accent) : AnyShapeStyle(.secondary))
                Text(helper.goal)
                    .font(LK.Typography.subheadline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(LKDelegationText.detail(helper, now: context.date))
                        .font(LK.Typography.caption)
                        .foregroundStyle(helper.status == "blocked" ? AnyShapeStyle(LK.Palette.warning) : AnyShapeStyle(.secondary))
                        .lineLimit(2)
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

struct LKDelegationStatusIcon: View {
    let status: String

    var body: some View {
        switch status {
        case "working", "finishing":
            ProgressView().controlSize(.mini)
                .frame(width: 16, height: 16)
                .accessibilityLabel(status == "working" ? "Working" : "Finishing")
        case "waiting":
            icon("clock", .secondary, "Waiting to start")
        case "blocked":
            icon("exclamationmark.triangle.fill", LK.Palette.warning, "Blocked")
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

/// Delegated work opened from the card: the whole task and what came back.
struct LKDelegationDetail: View {
    let helper: HelpersTree.Helper
    let nameFor: (String) -> String
    let stopping: Bool
    let stop: (() -> Void)?
    let taskView: ((_ board: String, _ task: String) -> AnyView)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LK.Spacing.lg) {
                    HStack(alignment: .top, spacing: LK.Spacing.sm) {
                        LKDelegationStatusIcon(status: helper.status)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(LKDelegationText.detail(helper, now: context.date))
                                .font(LK.Typography.subheadline)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    section("Task") { Text(helper.goal).textSelection(.enabled) }
                    if let summary = helper.summary, !summary.isEmpty {
                        section(helper.isOpen ? "Latest" : "What came back") {
                            Text(LKMessageBubble.markdown(summary)).textSelection(.enabled)
                        }
                    } else if !helper.isOpen {
                        Text("Nothing came back.")
                            .font(LK.Typography.footnote)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: LK.Spacing.md) {
                        if let task = helper.task, let taskView {
                            NavigationLink {
                                taskView(helper.board ?? "", task)
                            } label: {
                                Label("Open in Board", systemImage: "rectangle.split.3x1")
                            }
                            .buttonStyle(.bordered)
                        }
                        if helper.canStop, let stop {
                            Button(role: .destructive, action: stop) {
                                if stopping { ProgressView() } else { Label("Stop", systemImage: "stop.fill") }
                            }
                            .buttonStyle(.bordered)
                            .disabled(stopping || helper.doing == "Stopping")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(LK.Spacing.lg)
            }
            .navigationTitle(LKDelegationText.who(helper, nameFor: nameFor))
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
public enum LKDelegationText {
    public static func who(_ helper: HelpersTree.Helper, nameFor: (String) -> String) -> String {
        helper.agent.map(nameFor) ?? "Sub-agent"
    }

    public static func summary(_ tree: HelpersTree) -> String {
        let n = tree.helpers.count
        let open = tree.openCount
        let blocked = tree.helpers.filter { $0.status == "blocked" }.count
        if open == 0 {
            let failed = tree.helpers.filter { $0.status == "failed" || $0.status == "timed_out" }.count
            let base = n == 1 ? "Finished" : "All \(n) finished"
            return failed > 0 ? "\(base), \(failed) didn't make it" : base
        }
        var text = n == 1 ? "In progress" : "\(open) of \(n) still going"
        if blocked > 0 { text += blocked == 1 ? " · 1 blocked" : " · \(blocked) blocked" }
        return text
    }

    public static func detail(_ helper: HelpersTree.Helper, now: Date) -> String {
        var parts: [String] = []
        switch helper.status {
        case "waiting": parts.append("Waiting to start")
        case "working": parts.append(helper.doing ?? "Working")
        case "finishing": parts.append("Finishing")
        case "blocked":
            let why = helper.doing ?? ""
            parts.append(why.hasPrefix("Blocked") ? why : (why.isEmpty ? "Blocked" : "Blocked: \(why)"))
        case "done": parts.append("Done")
        case "failed": parts.append("Failed")
        case "timed_out": parts.append("Timed out")
        default: parts.append("Stopped")
        }
        if helper.steps > 0 { parts.append(helper.steps == 1 ? "1 step" : "\(helper.steps) steps") }
        if let start = helper.startedDate, helper.status != "blocked" {
            let end = helper.isOpen ? now : (helper.endedDate ?? now)
            parts.append(elapsed(max(0, end.timeIntervalSince(start))))
        }
        return parts.joined(separator: " · ")
    }

    public static func elapsed(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.down))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        if s < 86400 { return "\(s / 3600)h \(s % 3600 / 60)m" }
        return "\(s / 86400)d \(s % 86400 / 3600)h"
    }
}

#Preview("Delegated") {
    let now = Date()
    func at(_ ago: TimeInterval) -> String { (now - ago).formatted(.iso8601) }
    let tree = HelpersTree(status: "working", helpers: [
        .init(id: "t_1", goal: "Get the staging server's backups working again", agent: "researcher",
              task: "t_1", board: "default", status: "blocked",
              doing: "Blocked: needs the user to approve access to the backup bucket", started_at: at(900)),
        .init(id: "t_2", parent: "t_1", goal: "Check which backup jobs failed this week", agent: "coder",
              task: "t_2", board: "default", status: "working", doing: "Picked up by coder", started_at: at(240)),
        .init(id: "t_3", goal: "Publish the pricing page", agent: "coder", task: "t_3", board: "default",
              status: "done", started_at: at(3000), ended_at: at(600), summary: "Live at /pricing"),
        .init(id: "sa-0", goal: "Compare three hotels near the venue", status: "working", doing: "Web search",
              steps: 6, started_at: at(83)),
        .init(id: "t_4", goal: "Write the release notes", agent: "writer", task: "t_4", status: "waiting",
              started_at: at(20)),
    ])
    return ScrollView {
        LKDelegationCard(tree, agentName: "Assistant", nameFor: { $0.capitalized }, stop: { _ in },
                         taskView: { _, task in AnyView(Text(task)) })
            .padding()
    }
}
