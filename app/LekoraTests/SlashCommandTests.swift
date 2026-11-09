import XCTest
@testable import Lekora

/// Slash-command suggestions (docs/slash-commands.md).
@MainActor
final class SlashCommandTests: XCTestCase {
    private let commands = [
        SlashCommand(name: "new", description: "Start a new session", aliases: ["reset"]),
        SlashCommand(name: "approvals", description: "Approval mode", args: "[manual|smart|off]",
                     choices: ["manual", "smart", "off"]),
        SlashCommand(name: "model", description: "Switch model", args: "[model]"),
        SlashCommand(name: "ramen-finder", description: "Find ramen", group: "skill"),
    ]

    private func titles(_ draft: String) -> [String] {
        LKCommandMatcher.suggestions(for: draft, commands: commands).map(\.title)
    }

    func testSlashAloneListsEverything() {
        XCTAssertEqual(titles("/"), ["/new", "/approvals", "/model", "/ramen-finder"])
    }

    func testTypingNarrowsTheList() {
        XCTAssertEqual(titles("/a"), ["/approvals", "/ramen-finder"], "starts-with first, then contains")
        XCTAssertEqual(titles("/re"), ["/new"], "matches the alias /reset")
        XCTAssertEqual(titles("/men"), ["/ramen-finder"], "then anything containing it")
        XCTAssertEqual(titles("/zzz"), [])
    }

    func testNotACommand() {
        XCTAssertEqual(titles("hello /new"), [])
        XCTAssertEqual(titles("/new\nmore"), [])
        XCTAssertEqual(LKCommandMatcher.suggestions(for: "/", commands: []), [])
    }

    func testPickingInsertsTheCommand() {
        let new = LKCommandMatcher.suggestions(for: "/ne", commands: commands)[0]
        XCTAssertEqual(new.insert, "/new", "nothing more to type")
        let model = LKCommandMatcher.suggestions(for: "/mo", commands: commands)[0]
        XCTAssertEqual(model.insert, "/model ", "room for its argument")
        XCTAssertEqual(model.hint, "[model]")
        XCTAssertEqual(titles("/new"), [], "a complete command needs no list")
    }

    func testOptionsAfterTheCommand() {
        XCTAssertEqual(titles("/approvals "), ["manual", "smart", "off"])
        XCTAssertEqual(titles("/approvals s"), ["smart"])
        XCTAssertEqual(LKCommandMatcher.suggestions(for: "/approvals s", commands: commands)[0].insert, "/approvals smart")
        XCTAssertEqual(titles("/approvals smart"), [], "already complete")
        XCTAssertEqual(titles("/model gpt"), [], "no fixed options")
    }

    func testCommandsLoadFromTheHost() async throws {
        let host = try FakeHost()
        try await host.start()
        defer { host.stop() }
        let store = InMemoryCredentialStore()
        try SavedHost(instanceId: host.instanceId, instanceName: host.instanceName, deviceId: "dev_1",
                      deviceToken: host.acceptedDeviceToken, endpoints: [host.endpoint],
                      enabledProfileIds: ["assistant"], activeProfileId: "assistant").save(to: store)
        let gateway = GatewayClient(keychain: store, requireTLS: false)
        await gateway.resumeSavedSession()
        await gateway.loadCommands(for: "assistant")
        XCTAssertEqual(gateway.commands["assistant"]?.map(\.name), ["new", "approvals"])
        XCTAssertEqual(gateway.commands["assistant"]?.last?.choices, ["manual", "smart", "off"])
        XCTAssertEqual(host.received(type: "commands.list").last?["profile_id"] as? String, "assistant")
    }
}
