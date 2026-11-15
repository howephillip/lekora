import XCTest
@testable import Lekora

/// Syntax colours for code artifacts (docs/artifacts.md, "Code").
final class CodeHighlighterTests: XCTestCase {
    private func kinds(_ code: String, _ language: String) -> [String: CodeHighlighter.Kind] {
        var out: [String: CodeHighlighter.Kind] = [:]
        for segment in CodeHighlighter.segments(code, language: language) {
            out[segment.text.trimmingCharacters(in: .whitespacesAndNewlines)] = segment.kind
        }
        return out
    }

    func testNothingIsLost() {
        let code = "def f(x):\n    return \"hi\"  # done\n"
        XCTAssertEqual(CodeHighlighter.segments(code, language: "python").map(\.text).joined(), code)
    }

    func testJSONKeysAndValues() {
        let k = kinds(#"{ "name": "x", "count": 3, "ok": true, "none": null }"#, "json")
        XCTAssertEqual(k[#""name""#], .key)
        XCTAssertEqual(k[#""x""#], .string)
        XCTAssertEqual(k["3"], .number)
        XCTAssertEqual(k["true"], .number)
    }

    func testYAML() {
        let k = kinds("board: default\ncards:\n  - id: t_1\n    done: false # later\n", "yaml")
        XCTAssertEqual(k["board"], .key)
        XCTAssertEqual(k["id"], .key)
        XCTAssertEqual(k["false"], .number)
        XCTAssertEqual(k["# later"], .comment)
        let items = "tags:\n  - alpha\n  - beta\n"
        XCTAssertEqual(CodeHighlighter.segments(items, language: "yaml").map(\.text).joined(), items,
                       "list items keep every letter")
    }

    func testBash() {
        let k = kinds("#!/bin/bash\nif [ -n \"$HOME\" ]; then echo ${USER}; fi\n", "bash")
        XCTAssertEqual(k["#!/bin/bash"], .comment)
        XCTAssertEqual(k["if"], .keyword)
        XCTAssertEqual(k["${USER}"], .variable)
        XCTAssertEqual(k["\"$HOME\""], .string)
    }

    func testSQLIsCaseInsensitive() {
        let k = kinds("SELECT count(*) FROM cards WHERE status = 'done' -- recent\n", "sql")
        XCTAssertEqual(k["SELECT"], .keyword)
        XCTAssertEqual(k["FROM"], .keyword)
        XCTAssertEqual(k["'done'"], .string)
        XCTAssertEqual(k["-- recent"], .comment)
    }

    func testTypeScriptAndJavaScript() {
        let k = kinds("interface Card<T> { id: string }\nconst x = `a ${b}`; // note\nfunction go() {}\n", "typescript")
        XCTAssertEqual(k["interface"], .keyword)
        XCTAssertEqual(k["Card"], .type)
        XCTAssertEqual(k["string"], .type)
        XCTAssertEqual(k["`a ${b}`"], .string)
        XCTAssertEqual(k["// note"], .comment)
        XCTAssertEqual(kinds("console.log(1)", "javascript")["log"], .function)
    }

    func testC() {
        let k = kinds("#include <stdio.h>\n/* block */\nint main(void) { return 0; }\n", "c")
        XCTAssertEqual(k["#include"], .keyword)
        XCTAssertEqual(k["/* block */"], .comment)
        XCTAssertEqual(k["int"], .type)
        XCTAssertEqual(k["main"], .function)
        XCTAssertEqual(k["<stdio.h>"], .string)
    }

    func testLua() {
        let k = kinds("local t = {} -- table\n--[[ long\ncomment ]]\nreturn nil\n", "lua")
        XCTAssertEqual(k["local"], .keyword)
        XCTAssertEqual(k["-- table"], .comment)
        XCTAssertEqual(k["--[[ long\ncomment ]]"], .comment)
        XCTAssertEqual(k["nil"], .number)
    }

    func testDockerfile() {
        let k = kinds("FROM python:3.12 AS base\n# deps\nRUN pip install -r requirements.txt\nENV PATH=$PATH\n", "dockerfile")
        XCTAssertEqual(k["FROM"], .keyword)
        XCTAssertEqual(k["RUN"], .keyword)
        XCTAssertEqual(k["# deps"], .comment)
        XCTAssertEqual(k["$PATH"], .variable)
        XCTAssertNotEqual(k["install"], .keyword, "only the first word of a line is an instruction")
        XCTAssertEqual(k["AS"], .keyword)
    }

    func testDiff() {
        let k = kinds("diff --git a/x b/x\n@@ -1,2 +1,2 @@\n-old\n+new\n same\n", "diff")
        XCTAssertEqual(k["diff --git a/x b/x"], .meta)
        XCTAssertEqual(k["@@ -1,2 +1,2 @@"], .hunk)
        XCTAssertEqual(k["-old"], .removed)
        XCTAssertEqual(k["+new"], .added)
    }

    func testHTML() {
        let k = kinds(#"<div class="a"><!-- c --></div>"#, "html")
        XCTAssertEqual(k["<div"], .tag)
        XCTAssertEqual(k["class"], .attribute)
        XCTAssertEqual(k[#""a""#], .string)
        XCTAssertEqual(k["<!-- c -->"], .comment)
    }

    func testNamesAndTheViewer() {
        XCTAssertEqual(ArtifactRendering.kindName("code", language: "json"), "JSON")
        XCTAssertEqual(ArtifactRendering.kindName("code", language: "typescript"), "TypeScript")
        XCTAssertEqual(ArtifactRendering.fileName(title: "Card", kind: "code", language: "dockerfile"), "Dockerfile")
        XCTAssertEqual(ArtifactRendering.fileName(title: "Fix", kind: "code", language: "diff"), "Fix.diff")
        let page = ArtifactRendering.html(kind: "code", content: "let x = 1", language: "swift", wrap: true, codeSize: 15)
        XCTAssertTrue(page.contains("<span class=\"keyword\">let</span>"))
        XCTAssertTrue(page.contains("text-size-adjust: 100%"), "iOS never enlarges wide code unevenly")
        XCTAssertTrue(page.contains("class=\"wrap\"") && page.contains("--code-size: 15px"))
        XCTAssertTrue(Markdown.html("```python\nimport os\n```").contains("<span class=\"keyword\">import</span>"),
                      "code blocks in documents are coloured too")
    }
}
