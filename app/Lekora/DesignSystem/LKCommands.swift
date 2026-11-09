import SwiftUI

// Slash-command suggestions above the message bar (docs/slash-commands.md).

/// One row in the suggestions: a command, or one of a command's options.
public struct LKCommandSuggestion: Identifiable, Equatable {
    public var id: String { insert }
    /// "/approvals" or "smart"
    public let title: String
    /// e.g. "[manual|smart|off]"
    public let hint: String
    public let detail: String
    /// What the message bar holds after tapping it.
    public let insert: String
}

public enum LKCommandMatcher {
    /// Suggestions for what's typed so far: commands while typing the name after "/",
    /// then a command's fixed options after a space. Empty when it isn't a command.
    public static func suggestions(for draft: String, commands: [SlashCommand], limit: Int = 30) -> [LKCommandSuggestion] {
        guard draft.hasPrefix("/"), !draft.contains("\n"), !commands.isEmpty else { return [] }
        let body = draft.dropFirst()
        if let space = body.firstIndex(of: " ") {
            // "/approvals sm" -> the options of /approvals starting with "sm"
            let name = body[..<space].lowercased()
            let rest = body[body.index(after: space)...]
            guard !rest.contains(" "),
                  let command = commands.first(where: { $0.name.lowercased() == name || $0.aliases.contains { $0.lowercased() == name } }),
                  !command.choices.isEmpty else { return [] }
            let typed = rest.lowercased()
            let options = command.choices.filter { typed.isEmpty || $0.lowercased().hasPrefix(typed) }
            if options.count == 1, options[0].lowercased() == typed { return [] }  // already complete
            return options.map {
                LKCommandSuggestion(title: $0, hint: "", detail: "/\(command.name) \($0)", insert: "/\(command.name) \($0)")
            }
        }
        let typed = body.lowercased()
        func matches(_ text: String) -> Bool { text.lowercased().hasPrefix(typed) }
        // Names that start with what's typed first, then aliases, then anything containing it.
        var ordered = commands.filter { matches($0.name) }
        ordered += commands.filter { !matches($0.name) && $0.aliases.contains(where: matches) }
        if !typed.isEmpty {
            ordered += commands.filter { command in
                !ordered.contains(command) && command.name.lowercased().contains(typed)
            }
        }
        if ordered.count == 1, ordered[0].name.lowercased() == typed, !ordered[0].takesArguments { return [] }
        return ordered.prefix(limit).map { command in
            LKCommandSuggestion(title: "/\(command.name)", hint: command.args, detail: command.description,
                                insert: "/\(command.name)" + (command.takesArguments ? " " : ""))
        }
    }
}

/// The list shown above the message bar while typing a command.
public struct LKCommandSuggestions: View {
    private let suggestions: [LKCommandSuggestion]
    private let onPick: (LKCommandSuggestion) -> Void

    public init(_ suggestions: [LKCommandSuggestion], onPick: @escaping (LKCommandSuggestion) -> Void) {
        self.suggestions = suggestions
        self.onPick = onPick
    }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(suggestions) { suggestion in
                    Button {
                        onPick(suggestion)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: LK.Spacing.xs) {
                                Text(suggestion.title)
                                    .font(LK.Typography.body.weight(.semibold))
                                    .foregroundStyle(.primary)
                                if !suggestion.hint.isEmpty {
                                    Text(suggestion.hint)
                                        .font(LK.Typography.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            if !suggestion.detail.isEmpty {
                                Text(suggestion.detail)
                                    .font(LK.Typography.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, LK.Spacing.lg)
                        .padding(.vertical, LK.Spacing.sm)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if suggestion != suggestions.last {
                        Divider().padding(.leading, LK.Spacing.lg)
                    }
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: 260)
        .fixedSize(horizontal: false, vertical: true)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: LK.Radius.card, style: .continuous))
        .padding(.horizontal, LK.Spacing.lg)
        .accessibilityLabel("Command suggestions")
    }
}

#Preview("Command suggestions") {
    let commands = [
        SlashCommand(name: "new", description: "Start a new session (fresh session ID + history)", aliases: ["reset"]),
        SlashCommand(name: "approvals", description: "Show or change how risky commands are approved",
                     args: "[manual|smart|off]", choices: ["manual", "smart", "off"]),
        SlashCommand(name: "model", description: "Switch model for this session", args: "[model] [--provider name]"),
        SlashCommand(name: "ramen-finder", description: "Find ramen nearby", group: "skill"),
    ]
    VStack(spacing: 24) {
        Spacer()
        LKCommandSuggestions(LKCommandMatcher.suggestions(for: "/", commands: commands)) { _ in }
        LKCommandSuggestions(LKCommandMatcher.suggestions(for: "/approvals ", commands: commands)) { _ in }
    }
    .preferredColorScheme(.dark)
}
