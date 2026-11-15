import Foundation

/// How an artifact is shown (docs/artifacts.md): every kind becomes one HTML page for the
/// sealed web view. Web pages and images as they are; documents (Markdown), code and text are
/// laid out here, with styles that follow light and dark mode.
public enum ArtifactRendering {
    public static func html(kind: String, content: String, language: String? = nil) -> String {
        switch kind {
        case "html":
            return withViewport(content)
        case "svg":
            return page(body: "<div class=\"svg\">\(content)</div>", extraStyle: svgStyle)
        case "markdown":
            return page(body: Markdown.html(content))
        case "code":
            return page(body: codeBlock(content, language: language), extraStyle: codeStyle)
        default:
            return page(body: "<pre class=\"text\">\(escape(content))</pre>")
        }
    }

    /// The file it's shared as.
    public static func fileName(title: String, kind: String, language: String?) -> String {
        let base = title.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        let name = base.isEmpty ? "Artifact" : String(base.prefix(80))
        let ext: String
        switch kind {
        case "html": ext = "html"
        case "markdown": ext = "md"
        case "svg": ext = "svg"
        case "code": ext = codeExtension(language)
        default: ext = "txt"
        }
        return name.hasSuffix("." + ext) ? name : "\(name).\(ext)"
    }

    /// Web pages and images can be made into PDFs; so can documents and code.
    public static func kindName(_ kind: String, language: String? = nil) -> String {
        switch kind {
        case "html": return "Web page"
        case "markdown": return "Document"
        case "svg": return "Image"
        case "code": return language.map { "\($0.capitalized) code" } ?? "Code"
        default: return "Text"
        }
    }

    public static func symbol(_ kind: String) -> String {
        switch kind {
        case "html": return "globe"
        case "markdown": return "doc.richtext"
        case "svg": return "photo"
        case "code": return "chevron.left.forwardslash.chevron.right"
        default: return "doc.plaintext"
        }
    }

    // MARK: - Pieces

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func withViewport(_ html: String) -> String {
        // Phone-sized unless the page says otherwise.
        if html.range(of: "name=\"viewport\"", options: .caseInsensitive) != nil
            || html.range(of: "name=viewport", options: .caseInsensitive) != nil { return html }
        let meta = "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
        if let head = html.range(of: "<head>", options: .caseInsensitive) {
            var out = html
            out.insert(contentsOf: meta, at: head.upperBound)
            return out
        }
        return meta + html
    }

    static func codeBlock(_ code: String, language: String?) -> String {
        let lines = code.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let rows = lines.enumerated().map { index, line in
            "<tr><td class=\"n\">\(index + 1)</td><td class=\"l\">\(escape(line).isEmpty ? " " : escape(line))</td></tr>"
        }.joined()
        return "<div class=\"code\"><table>\(rows)</table></div>"
    }

    static func codeExtension(_ language: String?) -> String {
        let known = ["python": "py", "swift": "swift", "javascript": "js", "typescript": "ts", "js": "js",
                     "ts": "ts", "ruby": "rb", "rust": "rs", "go": "go", "java": "java", "kotlin": "kt",
                     "c": "c", "cpp": "cpp", "c++": "cpp", "csharp": "cs", "c#": "cs", "shell": "sh",
                     "bash": "sh", "sh": "sh", "zsh": "sh", "html": "html", "css": "css", "json": "json",
                     "yaml": "yaml", "yml": "yaml", "sql": "sql", "php": "php", "markdown": "md", "xml": "xml",
                     "toml": "toml", "lua": "lua", "r": "r", "dart": "dart", "scala": "scala"]
        guard let language = language?.lowercased().trimmingCharacters(in: .whitespaces), !language.isEmpty else { return "txt" }
        return known[language] ?? "txt"
    }

    static func page(body: String, extraStyle: String = "") -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>\(baseStyle)\(extraStyle)</style></head><body>\(body)</body></html>
        """
    }

    static let baseStyle = """
    :root { color-scheme: light dark; }
    body { font: -apple-system-body; font-family: -apple-system, system-ui, sans-serif; margin: 0;
           padding: 16px 18px 48px; line-height: 1.5; word-wrap: break-word; }
    h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.2em 0 0.5em; }
    h1 { font-size: 1.6em; } h2 { font-size: 1.35em; } h3 { font-size: 1.15em; }
    p, ul, ol, blockquote, table, pre { margin: 0 0 0.9em; }
    a { color: #0a84ff; }
    code { font-family: ui-monospace, Menlo, monospace; font-size: 0.9em; background: rgba(127,127,127,0.15);
           padding: 0.1em 0.3em; border-radius: 4px; }
    pre { background: rgba(127,127,127,0.12); padding: 12px; border-radius: 10px; overflow-x: auto; }
    pre code { background: none; padding: 0; }
    pre.text { background: none; padding: 0; white-space: pre-wrap; font-family: -apple-system, system-ui, sans-serif; }
    blockquote { border-left: 3px solid rgba(127,127,127,0.4); margin-left: 0; padding-left: 12px; color: gray; }
    table { border-collapse: collapse; display: block; overflow-x: auto; }
    th, td { border: 1px solid rgba(127,127,127,0.3); padding: 6px 10px; text-align: left; }
    th { background: rgba(127,127,127,0.1); }
    hr { border: none; border-top: 1px solid rgba(127,127,127,0.3); margin: 1.5em 0; }
    img { max-width: 100%; }
    """

    static let codeStyle = """
    body { padding: 0; }
    .code { overflow-x: auto; font-family: ui-monospace, Menlo, monospace; font-size: 13px; line-height: 1.45; }
    .code table { border: none; display: table; margin: 0; }
    .code td { border: none; padding: 0 12px 0 0; vertical-align: top; }
    .code td.n { color: gray; text-align: right; user-select: none; padding: 0 12px 0 14px; opacity: 0.7; }
    .code td.l { white-space: pre; }
    .code tr:first-child td { padding-top: 14px; }
    """

    static let svgStyle = """
    .svg { display: flex; justify-content: center; }
    .svg svg { max-width: 100%; height: auto; }
    """
}

/// A small Markdown reader for documents: headings, paragraphs, lists (nested by indent),
/// quotes, code blocks, tables, rules, and inline bold, italic, strikethrough, code, links
/// and images. Everything written is escaped, so a document can't carry its own HTML.
public enum Markdown {
    public static func html(_ source: String) -> String {
        var out: [String] = []
        var lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")[...]
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            out.append("<p>" + paragraph.map(inline).joined(separator: "<br>") + "</p>")
            paragraph = []
        }

        while let line = lines.first {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                lines = lines.dropFirst()
                var code: [String] = []
                while let next = lines.first, !next.trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(next)
                    lines = lines.dropFirst()
                }
                lines = lines.dropFirst()  // the closing fence
                out.append("<pre><code>\(ArtifactRendering.escape(code.joined(separator: "\n")))</code></pre>")
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                lines = lines.dropFirst()
                continue
            }
            if let heading = heading(trimmed) {
                flushParagraph()
                out.append("<h\(heading.level)>\(inline(heading.text))</h\(heading.level)>")
                lines = lines.dropFirst()
                continue
            }
            if isRule(trimmed) {
                flushParagraph()
                out.append("<hr>")
                lines = lines.dropFirst()
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while let next = lines.first, next.trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    var text = next.trimmingCharacters(in: .whitespaces).dropFirst()
                    if text.hasPrefix(" ") { text = text.dropFirst() }
                    quoted.append(String(text))
                    lines = lines.dropFirst()
                }
                out.append("<blockquote>\(html(quoted.joined(separator: "\n")))</blockquote>")
                continue
            }
            if let first = listItem(line) {
                flushParagraph()
                var items: [String] = []
                let base = indent(line)
                while let next = lines.first, listItem(next) != nil || (!next.trimmingCharacters(in: .whitespaces).isEmpty
                                                                         && indent(next) >= 2 && !items.isEmpty) {
                    // A numbered list straight after a bulleted one (or the reverse) is a new list.
                    if !items.isEmpty, let item = listItem(next), indent(next) <= base + 1, item.ordered != first.ordered { break }
                    items.append(next)
                    lines = lines.dropFirst()
                }
                out.append(list(items))
                continue
            }
            if trimmed.hasPrefix("|"), let next = lines.dropFirst().first, isTableDivider(next) {
                flushParagraph()
                var rows: [String] = [trimmed]
                lines = lines.dropFirst(2)
                while let row = lines.first, row.trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(row.trimmingCharacters(in: .whitespaces))
                    lines = lines.dropFirst()
                }
                out.append(table(rows))
                continue
            }
            paragraph.append(trimmed)
            lines = lines.dropFirst()
        }
        flushParagraph()
        return out.joined(separator: "\n")
    }

    static func heading(_ line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return (hashes, line.dropFirst(hashes + 1).trimmingCharacters(in: CharacterSet(charactersIn: " #")))
    }

    static func isRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        return compact.count >= 3 && (Set(compact) == ["-"] || Set(compact) == ["*"] || Set(compact) == ["_"])
    }

    static func indent(_ line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
    }

    /// (ordered, text) for a list item line.
    static func listItem(_ line: String) -> (ordered: Bool, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if let first = trimmed.first, "-*+".contains(first), trimmed.dropFirst().first == " ", !isRule(trimmed) {
            return (false, String(trimmed.dropFirst(2)))
        }
        let digits = trimmed.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 9 {
            let rest = trimmed.dropFirst(digits.count)
            if let mark = rest.first, ".)".contains(mark), rest.dropFirst().first == " " {
                return (true, String(rest.dropFirst(2)))
            }
        }
        return nil
    }

    /// Items at the first item's indent form this list; deeper ones nest under the item before.
    static func list(_ lines: [String]) -> String {
        guard let first = lines.first, let kind = listItem(first) else { return "" }
        let base = indent(first)
        var html = kind.ordered ? "<ol>" : "<ul>"
        var index = 0
        while index < lines.count {
            let line = lines[index]
            guard let item = listItem(line), indent(line) <= base + 1 else { index += 1; continue }
            var nested: [String] = []
            var continuation: [String] = []
            index += 1
            while index < lines.count, indent(lines[index]) > base + 1 {
                if listItem(lines[index]) != nil || !nested.isEmpty {
                    nested.append(lines[index])
                } else {
                    continuation.append(lines[index].trimmingCharacters(in: .whitespaces))
                }
                index += 1
            }
            var text = inline(checkbox(item.text))
            if !continuation.isEmpty { text += "<br>" + continuation.map(inline).joined(separator: "<br>") }
            html += "<li>\(text)\(nested.isEmpty ? "" : list(nested))</li>"
        }
        return html + (kind.ordered ? "</ol>" : "</ul>")
    }

    static func checkbox(_ text: String) -> String {
        if text.hasPrefix("[ ] ") { return "☐ " + text.dropFirst(4) }
        if text.lowercased().hasPrefix("[x] ") { return "☑ " + text.dropFirst(4) }
        return text
    }

    static func isTableDivider(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|") || trimmed.hasPrefix(":") || trimmed.hasPrefix("-") else { return false }
        return !trimmed.isEmpty && trimmed.allSatisfy { "|:- ".contains($0) } && trimmed.contains("-")
    }

    static func cells(_ row: String) -> [String] {
        var inner = row.trimmingCharacters(in: .whitespaces)
        if inner.hasPrefix("|") { inner.removeFirst() }
        if inner.hasSuffix("|") { inner.removeLast() }
        return inner.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func table(_ rows: [String]) -> String {
        guard let head = rows.first else { return "" }
        var html = "<table><thead><tr>" + cells(head).map { "<th>\(inline($0))</th>" }.joined() + "</tr></thead><tbody>"
        for row in rows.dropFirst() {
            html += "<tr>" + cells(row).map { "<td>\(inline($0))</td>" }.joined() + "</tr>"
        }
        return html + "</tbody></table>"
    }

    /// Inline marks, on escaped text: `code`, ![image](url), [link](url), **bold**, *italic*, ~~struck~~.
    static func inline(_ text: String) -> String {
        var codes: [String] = []
        // Code first, so its contents aren't read as other marks.
        var working = replace(#"`([^`]+)`"#, in: text) { groups in
            codes.append("<code>\(ArtifactRendering.escape(groups[1]))</code>")
            return "\u{0}\(codes.count - 1)\u{0}"
        }
        working = ArtifactRendering.escape(working)
        working = replace(#"!\[([^\]]*)\]\(([^)\s]+)\)"#, in: working) { groups in
            "<img alt=\"\(groups[1])\" src=\"\(safeURL(groups[2]))\">"
        }
        working = replace(#"\[([^\]]+)\]\(([^)\s]+)\)"#, in: working) { groups in
            "<a href=\"\(safeURL(groups[2]))\">\(groups[1])</a>"
        }
        working = replace(#"\*\*(.+?)\*\*|__(.+?)__"#, in: working) { groups in
            "<strong>\(groups[1].isEmpty ? groups[2] : groups[1])</strong>"
        }
        working = replace(#"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])|(?<![\w_])_(?!\s)(.+?)(?<!\s)_(?![\w_])"#, in: working) { groups in
            "<em>\(groups[1].isEmpty ? groups[2] : groups[1])</em>"
        }
        working = replace(#"~~(.+?)~~"#, in: working) { groups in "<del>\(groups[1])</del>" }
        for (index, code) in codes.enumerated() {
            working = working.replacingOccurrences(of: "\u{0}\(index)\u{0}", with: code)
        }
        return working
    }

    /// Links that can't run script in the page.
    static func safeURL(_ url: String) -> String {
        let lower = url.lowercased()
        if lower.hasPrefix("javascript:") || lower.hasPrefix("data:text/html") { return "#" }
        return url.replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func replace(_ pattern: String, in text: String, with make: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let groups = (0..<match.numberOfRanges).map { i -> String in
                let range = match.range(at: i)
                return range.location == NSNotFound ? "" : ns.substring(with: range)
            }
            result += make(groups)
            last = match.range.location + match.range.length
        }
        result += ns.substring(from: last)
        return result
    }
}
