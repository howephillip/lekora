import Foundation

/// The board's arrangement (docs/kanban.md): tasks grouped by status in Hermes' order, the moves
/// Hermes allows, and the words shown for them. Kept apart from the views so it can be tested.
public enum KanbanBoard {
    public struct Section: Identifiable, Equatable {
        public let key: String
        public let label: String
        public let tasks: [KanbanCard]
        public var id: String { key }
    }

    /// Statuses Hermes alone sets (a person can't move a task there).
    static let systemOnly: Set<String> = ["running"]
    public static let archived = "archived"

    /// One section per status, in the board's order; `assignee` keeps only that agent's tasks
    /// ("" = tasks nobody is assigned). Open tasks most important first, finished ones newest first.
    public static func sections(_ board: KanbanBoardResult, assignee: String? = nil,
                                includeEmpty: Bool = false) -> [Section] {
        let tasks = board.tasks.filter { task in
            guard let assignee else { return true }
            return assignee.isEmpty ? task.assignee == nil : task.assignee == assignee
        }
        var keys = board.columns.map(\.key)
        if tasks.contains(where: { $0.status == archived }) { keys.append(archived) }
        // A status this app doesn't know yet still shows (a newer Hermes).
        for task in tasks where !keys.contains(task.status) { keys.append(task.status) }
        return keys.compactMap { key in
            let inSection = sorted(tasks.filter { $0.status == key }, status: key)
            guard includeEmpty || !inSection.isEmpty else { return nil }
            return Section(key: key, label: label(key, in: board), tasks: inSection)
        }
    }

    static func sorted(_ tasks: [KanbanCard], status: String) -> [KanbanCard] {
        if status == "done" || status == archived {
            return tasks.sorted { ($0.completed_at ?? $0.created_at ?? 0) > ($1.completed_at ?? $1.created_at ?? 0) }
        }
        return tasks.sorted {
            $0.priority != $1.priority ? $0.priority > $1.priority : ($0.created_at ?? 0) > ($1.created_at ?? 0)
        }
    }

    public static func label(_ status: String, in board: KanbanBoardResult? = nil) -> String {
        if let column = board?.columns.first(where: { $0.key == status }) { return column.label }
        if status == archived { return "Archived" }
        return status.prefix(1).uppercased() + status.dropFirst()
    }

    /// Where a task can be moved from where it is, in the board's order (Archive last).
    public static func moves(for task: KanbanCard, in board: KanbanBoardResult) -> [String] {
        let allowed = Set(board.moves[task.status] ?? []).subtracting(systemOnly).subtracting([task.status])
        var order = board.columns.map(\.key)
        order.append(archived)
        return order.filter(allowed.contains)
    }

    /// "Move to Ready", "Archive", "Restore to Todo".
    public static func moveTitle(_ status: String, from current: String, in board: KanbanBoardResult) -> String {
        if status == archived { return "Archive" }
        if current == archived { return "Restore to \(label(status, in: board))" }
        return "Move to \(label(status, in: board))"
    }

    public static func symbol(_ status: String) -> String {
        switch status {
        case "triage": return "tray"
        case "todo": return "circle"
        case "scheduled": return "clock"
        case "ready": return "play.circle"
        case "running": return "bolt.circle.fill"
        case "blocked": return "exclamationmark.octagon"
        case "review": return "eye.circle"
        case "done": return "checkmark.circle.fill"
        case archived: return "archivebox"
        default: return "circle.dashed"
        }
    }

    /// Hermes' priority is a number (higher first); 0 is ordinary.
    public static func priorityLabel(_ priority: Int) -> String? {
        priority == 0 ? nil : "P\(priority)"
    }

    /// "5 min", "2 h 10 min", "3 days".
    public static func duration(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "under a minute" }
        let minutes = s / 60, hours = minutes / 60, days = hours / 24
        if days >= 1 { return "\(days) day\(days == 1 ? "" : "s")" }
        if hours >= 1 { return minutes % 60 == 0 ? "\(hours) h" : "\(hours) h \(minutes % 60) min" }
        return "\(minutes) min"
    }

    public static func date(_ seconds: Double?) -> Date? {
        seconds.map { Date(timeIntervalSince1970: $0) }
    }

    /// Who did a run, or who a task is for: the agent's name if it's one of this instance's.
    public static func agentName(_ profileId: String?, among profiles: [ProfileData]) -> String? {
        guard let profileId, !profileId.isEmpty else { return nil }
        return profiles.first { $0.profile_id == profileId }?.name ?? profileId
    }
}
