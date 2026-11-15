import XCTest
@testable import Lekora

/// Artifacts (docs/artifacts.md).
final class ArtifactsTests: XCTestCase {
    func testDocumentsAreLaidOut() {
        let html = Markdown.html("""
        # Plan
        Some **bold**, *soft* and `code` with a [link](https://example.com).

        - one
        - two
          - nested
        1. first

        > quoted

        | A | B |
        |---|---|
        | 1 | 2 |

        ```
        let x = 1 < 2
        ```
        ---
        """)
        XCTAssertTrue(html.contains("<h1>Plan</h1>"))
        XCTAssertTrue(html.contains("<strong>bold</strong>") && html.contains("<em>soft</em>") && html.contains("<code>code</code>"))
        XCTAssertTrue(html.contains("<a href=\"https://example.com\">link</a>"))
        XCTAssertTrue(html.contains("<ul><li>one</li><li>two<ul><li>nested</li></ul></li></ul>"))
        XCTAssertTrue(html.contains("<ol><li>first</li></ol>"))
        XCTAssertTrue(html.contains("<blockquote><p>quoted</p></blockquote>"))
        XCTAssertTrue(html.contains("<th>A</th>") && html.contains("<td>2</td>"))
        XCTAssertTrue(html.contains("let x = 1 &lt; 2"), "code is shown, not run")
        XCTAssertTrue(html.contains("<hr>"))
    }

    func testADocumentCantCarryItsOwnScript() {
        let html = Markdown.html("Hi <script>alert(1)</script> [x](javascript:alert(1))")
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertTrue(html.contains("href=\"#\""))
    }

    func testEachKindBecomesAPage() {
        XCTAssertTrue(ArtifactRendering.html(kind: "html", content: "<html><head></head><body>x</body></html>")
            .contains("name=\"viewport\""), "phone-sized")
        XCTAssertTrue(ArtifactRendering.html(kind: "code", content: "a\nb", language: "python").contains("<td class=\"n\">2</td>"))
        XCTAssertTrue(ArtifactRendering.html(kind: "text", content: "<b>").contains("&lt;b&gt;"))
        XCTAssertTrue(ArtifactRendering.html(kind: "svg", content: "<svg></svg>").contains("<svg></svg>"))
    }

    func testSharedFileNames() {
        XCTAssertEqual(ArtifactRendering.fileName(title: "Ramen / night", kind: "html", language: nil), "Ramen - night.html")
        XCTAssertEqual(ArtifactRendering.fileName(title: "Plan", kind: "markdown", language: nil), "Plan.md")
        XCTAssertEqual(ArtifactRendering.fileName(title: "Script", kind: "code", language: "Python"), "Script.py")
        XCTAssertEqual(ArtifactRendering.fileName(title: "", kind: "svg", language: nil), "Artifact.svg")
    }

    func testCardsAndRequestsDecode() throws {
        let json = #"{"seq":4,"role":"assistant","text":"","artifact":{"artifact_id":"art_1","title":"Plan","kind":"markdown","version":2,"action":"updated"}}"#
        let message = try JSONDecoder().decode(ChatMessageData.self, from: Data(json.utf8))
        XCTAssertEqual(message.artifact?.title, "Plan")
        XCTAssertEqual(message.artifact?.action, "updated")
        var timeline = ChatTimeline()
        timeline.applyIncoming(seq: 4, profileId: "a", role: "assistant", text: "", artifact: message.artifact)
        XCTAssertEqual(timeline.entries.first?.artifact?.version, 2)

        let envelope = GatewayClient.makeChatSendEnvelope(text: "Make it blue", instanceId: "i", profileId: "a", about: "art_1")
        let sent = try JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope)) as? [String: Any]
        XCTAssertEqual(((sent?["data"] as? [String: Any])?["about"] as? [String: Any])?["artifact_id"] as? String, "art_1")
    }

    @MainActor
    func testListOpenSaveAndFollowChanges() async throws {
        let host = try FakeHost()
        host.profiles = [["profile_id": "default", "name": "Default", "avatar": "sparkles"]]
        host.artifacts = [["artifact_id": "art_1", "title": "Plan", "kind": "markdown", "versions": ["# Plan"]]]
        try await host.start()
        defer { host.stop() }
        let store = InMemoryCredentialStore()
        try SavedHost(instanceId: host.instanceId, instanceName: host.instanceName, deviceId: "dev_1",
                      deviceToken: host.acceptedDeviceToken, endpoints: [host.endpoint],
                      enabledProfileIds: ["default"], activeProfileId: "default").save(to: store)
        let gateway = GatewayClient(keychain: store, requireTLS: false)
        await gateway.resumeSavedSession()

        let listed = try await gateway.artifacts(for: "default")
        XCTAssertEqual(listed.map(\.title), ["Plan"])
        let opened = try await gateway.artifact("art_1", in: "default")
        XCTAssertEqual(opened.content, "# Plan")
        let saved = try await gateway.saveArtifact("art_1", content: "# Plan\n- mine", baseVersion: 1, in: "default")
        XCTAssertEqual(saved.version, 2)
        do {
            _ = try await gateway.saveArtifact("art_1", content: "# stale", baseVersion: 1, in: "default")
            XCTFail("an edit from an older version is refused")
        } catch let error as HostError {
            XCTAssertEqual(error.code, "ARTIFACT_CHANGED")
        }
        let first = try await gateway.artifact("art_1", version: 1, in: "default")
        XCTAssertEqual(first.content, "# Plan", "earlier versions stay")

        host.announceArtifactChange("art_1", version: 3, profile: "default")
        let followed = await waitUntil { gateway.artifactVersions["art_1"] == 3 }
        XCTAssertTrue(followed, "an open viewer learns there's a newer version")
    }
}

