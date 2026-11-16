import Foundation

/// How an artifact is shown (docs/artifacts.md): every kind becomes one HTML page for the
/// sealed web view. Web pages and images as they are; documents (Markdown), code and text are
/// laid out here, with styles that follow light and dark mode.
public enum ArtifactRendering {
    /// - Parameters: wrap / codeSize: for code and text (the viewer's View menu).
    public static func html(kind: String, content: String, language: String? = nil,
                            wrap: Bool = false, codeSize: Int = 13, source: Bool = false,
                            thumbnail: Bool = false) -> String {
        if source || kind == "text" {
            // Lines you can comment on: code, plain text, or another kind's source (View › Show Source).
            return page(body: codeBlock(content, language: sourceLanguage(kind: kind, language: language)) + commentScript,
                        extraStyle: codeStyle + tokenStyle + commentStyle,
                        bodyClass: wrap || kind == "text" ? "wrap" : "", codeSize: codeSize)
        }
        switch kind {
        case "html":
            return withErrorReporting(withViewport(content))
        case "svg":
            return page(body: "<div class=\"svg\">\(content)</div>", extraStyle: svgStyle + (thumbnail ? fitStyle(".svg svg") : ""))
        case "mermaid":
            return mermaidPage(content, thumbnail: thumbnail)
        case "react":
            return reactPage(content)
        case "markdown":
            return page(body: Markdown.html(content), extraStyle: tokenStyle)
        case "code":
            return page(body: codeBlock(content, language: language) + commentScript,
                        extraStyle: codeStyle + tokenStyle + commentStyle,
                        bodyClass: wrap ? "wrap" : "", codeSize: codeSize)
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
        case "mermaid": ext = "mmd"
        case "react": ext = "jsx"
        case "code":
            if CodeHighlighter.canonical(language) == "dockerfile" { return "Dockerfile" }
            ext = codeExtension(language)
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
        case "mermaid": return "Diagram"
        case "react": return "Interactive"
        case "code": return CodeHighlighter.displayName(language) ?? "Code"
        default: return "Text"
        }
    }

    public static func symbol(_ kind: String) -> String {
        switch kind {
        case "html": return "globe"
        case "markdown": return "doc.richtext"
        case "svg": return "photo"
        case "mermaid": return "point.3.connected.trianglepath.dotted"
        case "react": return "square.stack.3d.up"
        case "code": return "chevron.left.forwardslash.chevron.right"
        default: return "doc.plaintext"
        }
    }

    // MARK: - Diagrams and interactive components (as Claude's artifacts)

    /// A Mermaid diagram, drawn by Mermaid (loaded online), in light or dark.
    /// A card's preview: the whole drawing shrunk to fit the card (a slice of a tall diagram can't be read).
    static func fitStyle(_ selector: String) -> String {
        "body { padding: 8px !important; } \(selector) { max-height: 166px !important; width: auto !important; max-width: 100% !important; display: block; margin: 0 auto; }"
    }

    static func mermaidPage(_ source: String, thumbnail: Bool = false) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>\(baseStyle) \(thumbnail ? fitStyle(".mermaid svg") : "") .mermaid { display: flex; justify-content: center; } .mermaid svg { max-width: 100%; height: auto; }
        .mermaid:not([data-processed]) { visibility: hidden; height: 0; }
        #drawing { text-align: center; color: gray; font-size: 14px; padding-top: 40px; }
        .mermaid[data-processed] ~ #drawing { display: none; }</style>
        </head><body><pre class="mermaid">\(escape(source))</pre><div id="drawing">Drawing the diagram…</div>
        <script type="module">
        import mermaid from "https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs";
        const dark = matchMedia("(prefers-color-scheme: dark)").matches;
        mermaid.initialize({ startOnLoad: false, theme: dark ? "dark" : "default", securityLevel: "strict" });
        try { await mermaid.run(); } catch (e) { console.error("Diagram error: " + (e && e.message || e)); throw e; }
        </script></body></html>
        """
    }

    /// One React component (JSX or TSX, default export), as Claude's interactive artifacts:
    /// React 18, hooks, Tailwind classes, other libraries by name (from esm.sh) or by URL.
    static func reactPage(_ source: String) -> String {
        let code = String(decoding: (try? JSONEncoder().encode(source)) ?? Data("\"\"".utf8), as: UTF8.self)
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <script src="https://cdn.tailwindcss.com"></script>
        <script src="https://unpkg.com/@babel/standalone@7/babel.min.js"></script>
        <script type="importmap">{"imports": {
          "react": "https://esm.sh/react@18.3.1", "react/": "https://esm.sh/react@18.3.1/",
          "react-dom": "https://esm.sh/react-dom@18.3.1", "react-dom/": "https://esm.sh/react-dom@18.3.1/"
        }}</script>
        <style>:root { color-scheme: light dark; } html { -webkit-text-size-adjust: 100%; }
        body { margin: 0; font-family: -apple-system, system-ui, sans-serif; }
        #lekora-error { white-space: pre-wrap; color: #cf222e; font: 13px ui-monospace, Menlo, monospace; padding: 16px; }</style>
        </head><body><div id="root"></div><div id="lekora-error"></div>
        <script type="module">
        const source = \(code);
        function fail(e) { const m = (e && (e.stack || e.message)) || String(e); document.getElementById("lekora-error").textContent = m; console.error(m); }
        try {
          let js = Babel.transform(source, { filename: "App.tsx", sourceType: "module",
            presets: [["react", { runtime: "classic" }], ["typescript", { isTSX: true, allExtensions: true }]] }).code;
          // Libraries by name come from esm.sh (sharing this page's React).
          js = js.replace(/from\\s+["']([^"'./][^"']*)["']/g, (all, name) =>
            /^(react|react-dom)(\\/|$)/.test(name) || /^https?:/.test(name) ? all
              : 'from "https://esm.sh/' + name + '?external=react,react-dom"');
          if (!/^\\s*import\\s+React\\b/m.test(js)) js = 'import React from "react";\\n' + js;
          const url = URL.createObjectURL(new Blob([js], { type: "text/javascript" }));
          const [{ default: App }, React, { createRoot }] = await Promise.all([import(url), import("react"), import("react-dom/client")]);
          if (!App) throw new Error("The component needs a default export (export default function App() { … }).");
          createRoot(document.getElementById("root")).render(React.createElement(App));
        } catch (e) { fail(e); }
        </script></body></html>
        """
    }

    // MARK: - What changed

    /// The previous version against this one, as a unified diff (for the Changes view).
    public static func changes(from old: String, to new: String) -> String {
        let before = old.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let after = new.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let difference = after.difference(from: before)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var out: [String] = []
        var i = 0, j = 0
        while i < before.count || j < after.count {
            if i < before.count, removed.contains(i) {
                out.append("-" + before[i]); i += 1
            } else if j < after.count, inserted.contains(j) {
                out.append("+" + after[j]); j += 1
            } else {
                if j < after.count { out.append(" " + after[j]) }
                i += 1; j += 1
            }
        }
        return out.joined(separator: "\n")
    }

    /// The Changes view: removed lines red, added green, the rest as it was.
    public static func changesPage(from old: String, to new: String, codeSize: Int = 13) -> String {
        page(body: codeBlock(changes(from: old, to: new), language: "diff"), extraStyle: codeStyle + tokenStyle,
             bodyClass: "wrap", codeSize: codeSize)
    }

    // MARK: - Pieces

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Reports the page's own errors with their real text (WebKit hides the text from scripts added
    /// from outside the page, showing only "Script error."), for "Ask the agent to fix".
    static let inlineErrorReporter = """
    <script>(function () {
      function send(m) { try { window.webkit.messageHandlers.lekoraErrors.postMessage(String(m).slice(0, 600)); } catch (e) {} }
      window.addEventListener('error', function (e) {
        var m = (e.error && e.error.message) || e.message || 'Error';
        send(m + (e.lineno ? ' (line ' + e.lineno + ')' : ''));
      }, true);
      window.addEventListener('unhandledrejection', function (e) { send('Unhandled: ' + ((e.reason && e.reason.message) || e.reason)); });
    })();</script>
    """

    static func withErrorReporting(_ html: String) -> String {
        if let head = html.range(of: "<head>", options: .caseInsensitive) {
            var out = html
            out.insert(contentsOf: inlineErrorReporter, at: head.upperBound)
            return out
        }
        if let body = html.range(of: "<body", options: .caseInsensitive) {
            var out = html
            out.insert(contentsOf: inlineErrorReporter, at: body.lowerBound)
            return out
        }
        return inlineErrorReporter + html
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

    /// Kinds shown as lines you can comment on (directly, or through Show Source).
    public static func commentable(kind: String, source: Bool) -> Bool {
        kind == "code" || kind == "text" || source
    }

    static func sourceLanguage(kind: String, language: String?) -> String {
        switch kind {
        case "react": return "typescript"
        case "mermaid": return "text"
        case "html": return "html"
        case "svg": return "xml"
        case "markdown": return "markdown"
        case "text": return "text"
        default: return language ?? ""
        }
    }

    /// The lines of `content` from `start` to `end` (1-based), for a comment's quote.
    public static func lines(_ content: String, from start: Int, to end: Int) -> String {
        let all = content.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard start >= 1, start <= all.count else { return "" }
        return all[(start - 1)..<min(end, all.count)].joined(separator: "\n")
    }

    /// Our own script on code pages (never the artifact's: its text is escaped): a tap on a line
    /// tells the app, and the app shows selected lines and comments. Only these pages get it.
    static let commentScript = """
    <script>
    (function () {
      function post(m) { try { window.webkit.messageHandlers.lekoraLines.postMessage(m); } catch (e) {} }
      document.addEventListener('click', function (e) {
        var bubble = e.target.closest('.cbubble');
        if (bubble) { post({ edit: bubble.dataset.id }); return; }
        var row = e.target.closest('tr[data-line]');
        if (!row || String(window.getSelection() || '').length > 0) return;
        post({ line: Number(row.dataset.line) });
      });
      window.lkSelect = function (a, b) {
        document.querySelectorAll('tr.sel').forEach(function (r) { r.classList.remove('sel'); });
        if (a == null) return;
        for (var i = a; i <= b; i++) {
          var r = document.querySelector('tr[data-line="' + i + '"]');
          if (r) r.classList.add('sel');
        }
      };
      window.lkComments = function (list) {
        document.querySelectorAll('tr.cmt').forEach(function (r) { r.remove(); });
        document.querySelectorAll('tr.has').forEach(function (r) { r.classList.remove('has'); });
        list.slice().reverse().forEach(function (c) {
          var last = document.querySelector('tr[data-line="' + c.end + '"]');
          if (!last) return;
          for (var i = c.start; i <= c.end; i++) {
            var r = document.querySelector('tr[data-line="' + i + '"]');
            if (r) r.classList.add('has');
          }
          var tr = document.createElement('tr'); tr.className = 'cmt';
          var n = document.createElement('td'); n.className = 'n'; tr.appendChild(n);
          var td = document.createElement('td'); td.className = 'l';
          var d = document.createElement('div'); d.className = 'cbubble'; d.dataset.id = c.id;
          var head = document.createElement('div'); head.className = 'chead'; head.textContent = c.label;
          var body = document.createElement('div'); body.textContent = c.text;
          d.appendChild(head); d.appendChild(body); td.appendChild(d); tr.appendChild(td);
          last.after(tr);
        });
      };
    })();
    </script>
    """

    static let commentStyle = """
    .code tr[data-line] { cursor: pointer; }
    .code tr.sel td { background: rgba(10,132,255,0.16); }
    .code tr.sel td.n { background: rgba(10,132,255,0.28); color: #0a84ff; font-weight: 700; }
    .code tr.has td.n { color: #c98a00; font-weight: 700; }
    .code tr.cmt td.l { white-space: normal; }
    .cbubble { position: sticky; left: 60px; display: inline-block; max-width: calc(100vw - 84px);
               white-space: pre-wrap; font-family: -apple-system, system-ui, sans-serif; font-size: 14px;
               line-height: 1.35; background: rgba(255,196,0,0.16); border-left: 3px solid #ffb800;
               border-radius: 8px; padding: 6px 10px; margin: 4px 0 8px; }
    .cbubble .chead { font-size: 11px; font-weight: 600; opacity: 0.65; margin-bottom: 2px; }
    """

    /// Code in coloured lines (CodeHighlighter), one table row per line with its number.
    static func codeBlock(_ code: String, language: String?) -> String {
        let source = code.replacingOccurrences(of: "\r\n", with: "\n")
        var lines: [String] = [""]
        for segment in CodeHighlighter.segments(source, language: language) {
            let pieces = segment.text.components(separatedBy: "\n")
            for (n, piece) in pieces.enumerated() {
                if n > 0 { lines.append("") }
                guard !piece.isEmpty else { continue }
                let text = escape(piece)
                lines[lines.count - 1] += segment.kind == .plain ? text : "<span class=\"\(segment.kind.rawValue)\">\(text)</span>"
            }
        }
        if lines.count > 1, lines.last?.isEmpty == true { lines.removeLast() }  // a file's final newline isn't a line
        let rows = lines.enumerated().map { index, line in
            "<tr data-line=\"\(index + 1)\"><td class=\"n\">\(index + 1)</td><td class=\"l\">\(line.isEmpty ? " " : line)</td></tr>"
        }.joined()
        return "<div class=\"code\"><table>\(rows)</table></div>"
    }

    static func codeExtension(_ language: String?) -> String {
        let known = ["python": "py", "swift": "swift", "javascript": "js", "typescript": "ts", "js": "js",
                     "ts": "ts", "ruby": "rb", "rust": "rs", "go": "go", "java": "java", "kotlin": "kt",
                     "c": "c", "cpp": "cpp", "c++": "cpp", "csharp": "cs", "c#": "cs", "shell": "sh",
                     "bash": "sh", "sh": "sh", "zsh": "sh", "html": "html", "css": "css", "json": "json",
                     "yaml": "yaml", "yml": "yaml", "sql": "sql", "php": "php", "markdown": "md", "xml": "xml",
                     "toml": "toml", "lua": "lua", "r": "r", "dart": "dart", "scala": "scala", "diff": "diff",
                     "patch": "patch", "jsx": "jsx", "tsx": "tsx", "makefile": "mk", "powershell": "ps1", "ini": "ini"]
        guard let language = language?.lowercased().trimmingCharacters(in: .whitespaces), !language.isEmpty else { return "txt" }
        return known[language] ?? known[CodeHighlighter.canonical(language)] ?? "txt"
    }

    static func page(body: String, extraStyle: String = "", bodyClass: String = "", codeSize: Int = 13) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>:root { --code-size: \(min(max(codeSize, 9), 24))px; }\(baseStyle)\(extraStyle)</style></head><body class="\(bodyClass)">\(body)</body></html>
        """
    }

    static let baseStyle = """
    :root { color-scheme: light dark; }
    /* Never let iOS enlarge text in wide pages (it did, unevenly, for long code lines). */
    html { -webkit-text-size-adjust: 100%; text-size-adjust: 100%; }
    body { font: -apple-system-body; font-family: -apple-system, system-ui, sans-serif; margin: 0;
           padding: 16px 18px 110px; line-height: 1.5; word-wrap: break-word; }
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
    li > ul, li > ol { margin: 0.15em 0 0.25em; }
    hr { border: none; border-top: 1px solid rgba(127,127,127,0.3); margin: 1.5em 0; }
    img { max-width: 100%; }
    """

    static let codeStyle = """
    body { padding: 0; }
    .code { overflow-x: auto; font-family: ui-monospace, Menlo, monospace; font-size: var(--code-size);
            line-height: 1.5; min-height: 100vh; box-sizing: border-box;
            padding: 12px 0 110px; /* space above, and clear of the bottom buttons (not part of any line) */ }
    .code table { border: none; display: table; margin: 0; border-collapse: collapse; width: max-content; min-width: 100%; }
    .code td { border: none; padding: 0 14px 0 0; vertical-align: top; }
    /* Line numbers stay put while the code scrolls sideways. */
    .code td.n { position: sticky; left: 0; background: Canvas; color: GrayText; text-align: right;
                 user-select: none; -webkit-user-select: none; padding: 0 10px 0 12px; min-width: 2ch;
                 border-right: 1px solid rgba(127,127,127,0.18); }
    .code td.l { white-space: pre; padding-left: 12px; width: 100%; }
    body.wrap .code table { width: 100%; }
    body.wrap .code td.l { white-space: pre-wrap; word-break: break-word; overflow-wrap: anywhere; }
    """

    static let tokenStyle = """
    /* Colours, light and dark (in the spirit of Xcode's defaults). */
    .keyword { color: #9b2393; font-weight: 600; }
    .type { color: #0b4f79; }
    .function { color: #326d74; }
    .string { color: #c41a16; }
    .number { color: #1c00cf; }
    .comment { color: #5d6c79; font-style: italic; }
    .key { color: #0b4f79; font-weight: 600; }
    .variable { color: #643820; }
    .tag { color: #9b2393; }
    .attribute { color: #815f03; }
    .added { color: #1a7f37; background: rgba(46,160,67,0.15); display: inline-block; min-width: 100%; }
    .removed { color: #cf222e; background: rgba(248,81,73,0.15); display: inline-block; min-width: 100%; }
    .hunk { color: #6f42c1; font-weight: 600; }
    .meta { color: #57606a; font-weight: 600; }
    @media (prefers-color-scheme: dark) {
      .keyword { color: #ff7ab2; } .type { color: #6bdfff; } .function { color: #67b7a4; }
      .string { color: #ff8170; } .number { color: #d9c97c; } .comment { color: #7f8c98; }
      .key { color: #6bdfff; } .variable { color: #b281eb; } .tag { color: #ff7ab2; } .attribute { color: #d9a15c; }
      .added { color: #7ee787; background: rgba(46,160,67,0.25); } .removed { color: #ffa198; background: rgba(248,81,73,0.25); }
      .hunk { color: #d2a8ff; } .meta { color: #8b949e; }
    }
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
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                lines = lines.dropFirst()
                var code: [String] = []
                while let next = lines.first, !next.trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(next)
                    lines = lines.dropFirst()
                }
                lines = lines.dropFirst()  // the closing fence
                out.append("<pre><code>\(highlighted(code.joined(separator: "\n"), language: language))</code></pre>")
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

    /// A fenced code block, coloured when it names its language (```python).
    static func highlighted(_ code: String, language: String) -> String {
        guard !language.isEmpty else { return ArtifactRendering.escape(code) }
        return CodeHighlighter.segments(code, language: language).map { segment in
            let text = ArtifactRendering.escape(segment.text)
            return segment.kind == .plain ? text : "<span class=\"\(segment.kind.rawValue)\">\(text)</span>"
        }.joined()
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
