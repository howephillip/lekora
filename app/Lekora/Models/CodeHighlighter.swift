import Foundation

/// Syntax colours for code artifacts (docs/artifacts.md, "Code"), on the phone and offline: the
/// viewer and the code editor both use it. Not a full parser: it knows each language's comments,
/// strings, numbers and keywords, plus the special shapes of JSON and YAML keys, diffs,
/// Dockerfiles and HTML/XML tags. Unknown languages still get comments, strings and numbers.
public enum CodeHighlighter {
    public enum Kind: String, CaseIterable, Sendable {
        case plain, keyword, type, function, string, number, comment, key, variable
        case tag, attribute, added, removed, hunk, meta
    }

    public struct Segment: Equatable, Sendable {
        public let text: String
        public let kind: Kind
    }

    /// How a language is shown by name ("JSON", "TypeScript"…).
    public static func displayName(_ language: String?) -> String? {
        guard let raw = language?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let names = ["json": "JSON", "yaml": "YAML", "yml": "YAML", "sql": "SQL", "javascript": "JavaScript", "js": "JavaScript",
                     "typescript": "TypeScript", "ts": "TypeScript", "tsx": "TypeScript", "jsx": "JavaScript",
                     "c": "C", "cpp": "C++", "c++": "C++", "csharp": "C#", "c#": "C#", "cs": "C#", "objc": "Objective-C",
                     "html": "HTML", "xml": "XML", "svg": "SVG", "css": "CSS", "scss": "SCSS", "php": "PHP", "toml": "TOML",
                     "ini": "INI", "bash": "Bash", "sh": "Shell", "shell": "Shell", "zsh": "Zsh", "dockerfile": "Dockerfile",
                     "docker": "Dockerfile", "diff": "Diff", "patch": "Diff", "lua": "Lua", "python": "Python", "py": "Python",
                     "swift": "Swift", "go": "Go", "golang": "Go", "rust": "Rust", "rs": "Rust", "kotlin": "Kotlin",
                     "kt": "Kotlin", "java": "Java", "ruby": "Ruby", "rb": "Ruby", "r": "R", "dart": "Dart", "scala": "Scala",
                     "perl": "Perl", "powershell": "PowerShell", "graphql": "GraphQL", "makefile": "Makefile", "markdown": "Markdown"]
        return names[raw.lowercased()] ?? raw.prefix(1).uppercased() + raw.dropFirst()
    }

    public static func segments(_ code: String, language: String?) -> [Segment] {
        let language = canonical(language)
        if language == "text" || language == "plaintext" { return code.isEmpty ? [] : [Segment(text: code, kind: .plain)] }
        var out: [Segment] = []
        switch language {
        case "diff": diff(code, into: &out)
        case "html", "xml": markup(code, into: &out)
        default: scan(code, spec: spec(for: language), into: &out)
        }
        return merged(out)
    }

    // MARK: - Languages

    static func canonical(_ language: String?) -> String {
        let raw = (language ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        let aliases = ["js": "javascript", "jsx": "javascript", "mjs": "javascript", "ts": "typescript", "tsx": "typescript",
                       "yml": "yaml", "sh": "bash", "shell": "bash", "zsh": "bash", "console": "bash", "py": "python",
                       "c++": "cpp", "cc": "cpp", "h": "c", "hpp": "cpp", "c#": "csharp", "cs": "csharp", "rs": "rust",
                       "golang": "go", "kt": "kotlin", "rb": "ruby", "patch": "diff", "docker": "dockerfile",
                       "svg": "xml", "htm": "html", "plist": "xml", "objc": "c", "objective-c": "c", "jsonc": "json",
                       "json5": "json", "ini": "toml", "make": "makefile", "ps1": "powershell"]
        return aliases[raw] ?? raw
    }

    struct Spec {
        var lineComments: [String] = []
        var blockComments: [(String, String)] = []
        /// Longest first ("\"\"\"" before "\"").
        var strings: [String] = ["\"", "'"]
        /// Strings that may run over several lines.
        var multilineStrings: Set<String> = []
        var keywords: Set<String> = []
        var constants: Set<String> = ["true", "false", "null"]
        var caseInsensitive = false
        /// Capitalised words are types (C-like languages).
        var capitalisedTypes = false
        var types: Set<String> = []
        /// `$name` / `${name}` are variables.
        var dollarVariables = false
        /// `name:` at the start of a line is a key (YAML).
        var lineKeys = false
        /// A string followed by `:` is a key (JSON).
        var stringKeys = false
        /// `@decorator`
        var atWords = false
        /// The first word of a line is an instruction (Dockerfile).
        var firstWordKeyword = false
    }

    static func words(_ list: String) -> Set<String> { Set(list.split(separator: " ").map(String.init)) }

    static let cTypes = words("int long short char float double void bool unsigned signed size_t uint8_t uint16_t uint32_t uint64_t int8_t int16_t int32_t int64_t FILE")

    static func spec(for language: String) -> Spec {
        var spec = Spec()
        let cLike: (String) -> Spec = { keywords in
            var s = Spec()
            s.lineComments = ["//"]
            s.blockComments = [("/*", "*/")]
            s.keywords = words(keywords)
            s.capitalisedTypes = true
            return s
        }
        switch language {
        case "javascript", "typescript":
            spec = cLike("break case catch class const continue debugger default delete do else export extends finally for from function if import in instanceof let new of return super switch this throw try typeof var void while with yield async await static get set as implements interface type enum namespace declare readonly private protected public abstract keyof infer is satisfies")
            spec.strings = ["`", "\"", "'"]
            spec.multilineStrings = ["`"]
            spec.constants = words("true false null undefined NaN Infinity")
            spec.types = language == "typescript" ? words("string number boolean any unknown never object symbol bigint void") : []
            spec.atWords = true
        case "c", "cpp":
            spec = cLike("auto break case const continue default do else enum extern for goto if inline register restrict return sizeof static struct switch typedef union volatile while class namespace template typename public private protected virtual override new delete this using try catch throw nullptr constexpr noexcept operator friend explicit mutable #include #define #ifdef #ifndef #endif #if #else #elif #pragma #undef")
            spec.types = cTypes.union(words("std string vector map"))
            spec.constants = words("true false NULL nullptr")
        case "csharp", "java", "kotlin", "scala", "dart", "go", "rust", "swift", "php", "groovy":
            spec = cLike("abstract as async await base bool break byte case catch char checked class const continue default delegate do double else enum event explicit extends extern final finally fixed float for foreach fun func go goto if impl implements import in init int interface internal is let lock long loop match mod module mut namespace new object open operator out override package private protected pub public readonly ref return sealed self Self short sizeof static struct super switch synchronized this throw throws trait try type typealias typeof uint ulong unsafe use using val var virtual void volatile when where while yield guard defer fallthrough repeat extension protocol inout some any deinit subscript chan select range map elif echo")
            spec.constants = words("true false null nil None")
            spec.atWords = true
            if language == "swift" || language == "kotlin" || language == "scala" || language == "dart" { spec.strings = ["\"\"\"", "\"", "'"]; spec.multilineStrings = ["\"\"\""] }
            if language == "go" { spec.strings = ["`", "\"", "'"]; spec.multilineStrings = ["`"] }
            if language == "php" { spec.dollarVariables = true; spec.lineComments = ["//", "#"] }
        case "python":
            spec.lineComments = ["#"]
            spec.strings = ["\"\"\"", "'''", "\"", "'"]
            spec.multilineStrings = ["\"\"\"", "'''"]
            spec.keywords = words("and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield match case self")
            spec.constants = words("True False None")
            spec.types = words("int float str bool list dict set tuple bytes object type Exception")
            spec.atWords = true
            spec.capitalisedTypes = true
        case "ruby":
            spec.lineComments = ["#"]
            spec.keywords = words("alias and begin break case class def defined? do else elsif end ensure for if in module next not or redo rescue retry return self super then undef unless until when while yield require attr_accessor")
            spec.constants = words("true false nil")
            spec.capitalisedTypes = true
        case "bash", "powershell", "makefile":
            spec.lineComments = ["#"]
            spec.keywords = words("if then else elif fi for while until do done case esac in function return local export readonly set unset shift exit source alias echo printf read cd test trap eval exec declare break continue")
            spec.constants = []
            spec.dollarVariables = true
        case "dockerfile":
            spec.lineComments = ["#"]
            spec.keywords = words("FROM RUN CMD LABEL MAINTAINER EXPOSE ENV ADD COPY ENTRYPOINT VOLUME USER WORKDIR ARG ONBUILD STOPSIGNAL HEALTHCHECK SHELL AS")
            spec.caseInsensitive = true
            spec.firstWordKeyword = true
            spec.dollarVariables = true
            spec.constants = []
        case "sql":
            spec.lineComments = ["--"]
            spec.blockComments = [("/*", "*/")]
            spec.strings = ["'", "\""]
            spec.keywords = words("select from where and or not insert into values update set delete create table view index drop alter add column primary key foreign references join left right inner outer full cross on group by order having limit offset as distinct union all exists in is null like between case when then else end with returning default unique check if begin commit rollback transaction asc desc count sum avg min max coalesce cast over partition")
            spec.types = words("int integer bigint smallint text varchar char boolean date timestamp datetime real float double numeric decimal blob json jsonb serial uuid")
            spec.constants = words("true false null")
            spec.caseInsensitive = true
        case "lua":
            spec.lineComments = ["--"]
            spec.blockComments = [("--[[", "]]")]
            spec.strings = ["[[", "\"", "'"]
            spec.multilineStrings = ["[["]
            spec.keywords = words("and break do else elseif end for function goto if in local not or repeat return then until while require self")
            spec.constants = words("true false nil")
        case "json":
            spec.strings = ["\""]
            spec.stringKeys = true
            spec.lineComments = ["//"]
            spec.blockComments = [("/*", "*/")]
        case "yaml", "toml":
            spec.lineComments = ["#"]
            spec.lineKeys = true
            spec.constants = words("true false null yes no on off True False Null ~")
        case "css", "scss", "less":
            spec.blockComments = [("/*", "*/")]
            spec.lineComments = language == "css" ? [] : ["//"]
            spec.keywords = words("@media @import @keyframes @font-face @supports !important")
            spec.lineKeys = false
            spec.atWords = true
        case "r":
            spec.lineComments = ["#"]
            spec.keywords = words("if else for while repeat function return next break in library")
            spec.constants = words("TRUE FALSE NULL NA Inf NaN")
        default:
            spec.lineComments = ["//", "#"]
            spec.blockComments = [("/*", "*/")]
        }
        return spec
    }

    // MARK: - The general scanner

    static func scan(_ code: String, spec: Spec, into out: inout [Segment]) {
        let chars = Array(code)
        let keywords = spec.caseInsensitive ? Set(spec.keywords.map { $0.lowercased() }) : spec.keywords
        var i = 0
        var plain = ""
        var lineStart = true        // only whitespace so far on this line
        var firstWordDone = false   // Dockerfile: the instruction is the first word

        func flush() {
            if !plain.isEmpty { out.append(Segment(text: plain, kind: .plain)); plain = "" }
        }
        func emit(_ text: String, _ kind: Kind) {
            flush()
            out.append(Segment(text: text, kind: kind))
        }
        func starts(_ token: String, at index: Int) -> Bool {
            let t = Array(token)
            guard index + t.count <= chars.count else { return false }
            for (n, c) in t.enumerated() where chars[index + n] != c { return false }
            return true
        }
        func isIdentStart(_ c: Character) -> Bool { c.isLetter || c == "_" }
        func isIdent(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }

        while i < chars.count {
            let c = chars[i]
            if c == "\n" {
                plain.append(c)
                i += 1
                lineStart = true
                firstWordDone = false
                continue
            }
            if lineStart, c == " " || c == "\t" {
                plain.append(c)
                i += 1
                continue
            }
            // YAML / TOML keys: `name:` (after an optional "- ") at the start of a line.
            if spec.lineKeys, lineStart {
                let i0 = i
                var j = i
                if chars[j] == "-", j + 1 < chars.count, chars[j + 1] == " " {
                    plain.append("- ")
                    j += 2
                    i = j
                }
                var k = j
                while k < chars.count, chars[k] != "\n", chars[k] != ":", chars[k] != "#", chars[k] != "\"", chars[k] != "'" { k += 1 }
                let isKey = k < chars.count && k > j && chars[k] == ":" && (k + 1 == chars.count || chars[k + 1] == " " || chars[k + 1] == "\n")
                if isKey {
                    emit(String(chars[j..<k]), .key)
                    i = k
                    lineStart = false
                    continue
                }
                if j != i0 {
                    // A list item that isn't a key: read its value from the start again.
                    lineStart = false
                    continue
                }
                if j < chars.count, chars[j] == "[" {  // TOML / INI section
                    var e = j
                    while e < chars.count, chars[e] != "\n" { e += 1 }
                    if e > j, chars[e - 1] == "]" || String(chars[j..<e]).trimmingCharacters(in: .whitespaces).hasSuffix("]") {
                        emit(String(chars[j..<e]), .key)
                        i = e
                        lineStart = false
                        continue
                    }
                }
            }
            lineStart = false

            // Comments.
            if let block = spec.blockComments.first(where: { starts($0.0, at: i) }) {
                var j = i + block.0.count
                while j < chars.count, !starts(block.1, at: j) { j += 1 }
                j = min(j + block.1.count, chars.count)
                emit(String(chars[i..<j]), .comment)
                i = j
                continue
            }
            if let line = spec.lineComments.first(where: { starts($0, at: i) }),
               line != "#" || i == 0 || chars[i - 1] == " " || chars[i - 1] == "\t" || chars[i - 1] == "\n" || spec.dollarVariables == false {
                var j = i
                while j < chars.count, chars[j] != "\n" { j += 1 }
                emit(String(chars[i..<j]), .comment)
                i = j
                continue
            }
            // Strings.
            if let quote = spec.strings.first(where: { starts($0, at: i) }) {
                let close = quote == "[[" ? "]]" : quote
                let multiline = spec.multilineStrings.contains(quote)
                var j = i + quote.count
                while j < chars.count {
                    if chars[j] == "\\", quote != "[[" { j += 2; continue }
                    if starts(close, at: j) { j += close.count; break }
                    if chars[j] == "\n", !multiline { break }
                    j += 1
                }
                j = min(j, chars.count)
                var kind = Kind.string
                if spec.stringKeys {
                    var k = j
                    while k < chars.count, chars[k] == " " || chars[k] == "\t" { k += 1 }
                    if k < chars.count, chars[k] == ":" { kind = .key }
                }
                emit(String(chars[i..<j]), kind)
                i = j
                continue
            }
            // Variables.
            if spec.dollarVariables, c == "$", i + 1 < chars.count, chars[i + 1] == "{" || isIdentStart(chars[i + 1]) || chars[i + 1].isNumber || "@#?*!".contains(chars[i + 1]) {
                var j = i + 1
                if chars[j] == "{" {
                    while j < chars.count, chars[j] != "}", chars[j] != "\n" { j += 1 }
                    j = min(j + 1, chars.count)
                } else if !isIdentStart(chars[j]) {
                    j += 1
                } else {
                    while j < chars.count, isIdent(chars[j]) { j += 1 }
                }
                emit(String(chars[i..<j]), .variable)
                i = j
                continue
            }
            // Numbers.
            if c.isNumber || (c == "." && i + 1 < chars.count && chars[i + 1].isNumber),
               i == 0 || !isIdent(chars[i - 1]) {
                var j = i
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "." || chars[j] == "_"
                        || ((chars[j] == "+" || chars[j] == "-") && j > i && "eE".contains(chars[j - 1]) && !starts("0x", at: i)) {
                    j += 1
                }
                emit(String(chars[i..<j]), .number)
                i = j
                continue
            }
            // Decorators / at-rules.
            if spec.atWords, c == "@", i + 1 < chars.count, isIdentStart(chars[i + 1]) {
                var j = i + 1
                while j < chars.count, isIdent(chars[j]) || chars[j] == "-" { j += 1 }
                emit(String(chars[i..<j]), .attribute)
                i = j
                continue
            }
            // Preprocessor lines (C): `#include <x>` reads as one keyword then the rest.
            if c == "#", spec.keywords.contains("#include") {
                var j = i + 1
                while j < chars.count, chars[j].isLetter { j += 1 }
                let word = String(chars[i..<j])
                if spec.keywords.contains(word) {
                    emit(word, .keyword)
                    i = j
                    if word == "#include" {
                        // `<stdio.h>` reads as a string, like "local.h".
                        while i < chars.count, chars[i] == " " { plain.append(" "); i += 1 }
                        if i < chars.count, chars[i] == "<" {
                            var e = i
                            while e < chars.count, chars[e] != ">", chars[e] != "\n" { e += 1 }
                            e = min(e + 1, chars.count)
                            emit(String(chars[i..<e]), .string)
                            i = e
                        }
                    }
                    continue
                }
            }
            // Words.
            if isIdentStart(c) {
                var j = i
                while j < chars.count, isIdent(chars[j]) { j += 1 }
                let word = String(chars[i..<j])
                let lookup = spec.caseInsensitive ? word.lowercased() : word
                var kind = Kind.plain
                if spec.firstWordKeyword {
                    // The instruction, and `AS` in `FROM image AS name`.
                    if (!firstWordDone && keywords.contains(lookup)) || word == "AS" { kind = .keyword }
                    firstWordDone = true
                } else if keywords.contains(lookup) {
                    kind = .keyword
                }
                if kind == .plain {
                    if spec.constants.contains(word) || (spec.caseInsensitive && spec.constants.contains(lookup)) {
                        kind = .number
                    } else if spec.types.contains(lookup) || spec.types.contains(word) || (spec.capitalisedTypes && word.first?.isUppercase == true && word.count > 1) {
                        kind = .type
                    } else {
                        var k = j
                        while k < chars.count, chars[k] == " " { k += 1 }
                        if k < chars.count, chars[k] == "(" { kind = .function }
                    }
                }
                if kind == .plain { plain += word } else { emit(word, kind) }
                i = j
                continue
            }
            plain.append(c)
            i += 1
        }
        flush()
    }

    // MARK: - Diffs

    static func diff(_ code: String, into out: inout [Segment]) {
        let lines = code.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            let kind: Kind
            if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") || line.hasPrefix("index ")
                || line.hasPrefix("new file") || line.hasPrefix("deleted file") || line.hasPrefix("similarity") || line.hasPrefix("rename ") {
                kind = .meta
            } else if line.hasPrefix("@@") {
                kind = .hunk
            } else if line.hasPrefix("+") {
                kind = .added
            } else if line.hasPrefix("-") {
                kind = .removed
            } else {
                kind = .plain
            }
            out.append(Segment(text: line, kind: kind))
            if index < lines.count - 1 { out.append(Segment(text: "\n", kind: .plain)) }
        }
    }

    // MARK: - HTML / XML / SVG

    static func markup(_ code: String, into out: inout [Segment]) {
        let chars = Array(code)
        var i = 0
        var plain = ""
        func flush() { if !plain.isEmpty { out.append(Segment(text: plain, kind: .plain)); plain = "" } }
        func emit(_ text: String, _ kind: Kind) { flush(); out.append(Segment(text: text, kind: kind)) }
        func starts(_ token: String, at index: Int) -> Bool {
            let t = Array(token)
            guard index + t.count <= chars.count else { return false }
            return Array(chars[index..<index + t.count]) == t
        }
        while i < chars.count {
            if starts("<!--", at: i) {
                var j = i + 4
                while j < chars.count, !starts("-->", at: j) { j += 1 }
                j = min(j + 3, chars.count)
                emit(String(chars[i..<j]), .comment)
                i = j
                continue
            }
            if chars[i] == "<", i + 1 < chars.count, chars[i + 1].isLetter || "/!?".contains(chars[i + 1]) {
                var j = i + 1
                while j < chars.count, !chars[j].isWhitespace, chars[j] != ">", !(chars[j] == "/" && j + 1 < chars.count && chars[j + 1] == ">") { j += 1 }
                emit(String(chars[i..<j]), .tag)
                i = j
                // Attributes until the tag closes.
                while i < chars.count, chars[i] != ">" {
                    if chars[i] == "\"" || chars[i] == "'" {
                        let quote = chars[i]
                        var e = i + 1
                        while e < chars.count, chars[e] != quote { e += 1 }
                        e = min(e + 1, chars.count)
                        emit(String(chars[i..<e]), .string)
                        i = e
                    } else if chars[i].isLetter || chars[i] == "-" || chars[i] == ":" || chars[i] == "@" {
                        var e = i
                        while e < chars.count, chars[e].isLetter || chars[e].isNumber || "-:_@.".contains(chars[e]) { e += 1 }
                        emit(String(chars[i..<e]), .attribute)
                        i = e
                    } else if chars[i] == "/" {
                        emit("/", .tag)
                        i += 1
                    } else {
                        plain.append(chars[i])
                        i += 1
                    }
                }
                if i < chars.count {
                    emit(">", .tag)
                    i += 1
                }
                continue
            }
            plain.append(chars[i])
            i += 1
        }
        flush()
    }

    static func merged(_ segments: [Segment]) -> [Segment] {
        var out: [Segment] = []
        for segment in segments where !segment.text.isEmpty {
            if let last = out.last, last.kind == segment.kind {
                out[out.count - 1] = Segment(text: last.text + segment.text, kind: last.kind)
            } else {
                out.append(segment)
            }
        }
        return out
    }
}
