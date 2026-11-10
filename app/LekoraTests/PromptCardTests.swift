import XCTest
@testable import Lekora

/// Approval and question cards (docs/prompts.md).
@MainActor
final class PromptCardTests: XCTestCase {
    private var host: FakeHost!

    override func setUp() async throws {
        host = try FakeHost()
        host.profiles = [
            ["profile_id": "default", "name": "Home", "avatar": "sparkles"],
            ["profile_id": "bruce", "name": "Bruce", "avatar": "sparkles"],
        ]
        host.history = [(1, "assistant", "Hi", "default")]
        try await host.start()
    }

    override func tearDown() async throws {
        host.stop()
        host = nil
    }

    private func connected(active: String = "default") async throws -> GatewayClient {
        let store = InMemoryCredentialStore()
        try SavedHost(instanceId: host.instanceId, instanceName: host.instanceName, deviceId: "dev_1",
                      deviceToken: host.acceptedDeviceToken, endpoints: [host.endpoint],
                      enabledProfileIds: ["default", "bruce"], activeProfileId: active).save(to: store)
        let gateway = GatewayClient(keychain: store, requireTLS: false)
        await gateway.resumeSavedSession()
        _ = await waitUntil { !gateway.timeline.entries.isEmpty }
        return gateway
    }

    private func approvalCard(id: String = "c_a1", expiresIn: TimeInterval = 300) -> [String: Any] {
        ["kind": "approval", "id": id, "status": "pending", "command": "rm -rf ./build",
         "description": "recursive delete", "choices": ["once", "session", "always", "deny"],
         "smart_denied": false,
         "expires_at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(expiresIn))]
    }

    private func questionCard(id: String = "c_q1", multi: Bool = false) -> [String: Any] {
        ["kind": "question", "id": id, "status": "pending", "question": "Which venue?",
         "choices": ["Ramen512", "Kemuri"], "multi_select": multi]
    }

    private func responses() -> [[String: Any]] {
        host.received(type: "prompt.respond").compactMap { $0["data"] as? [String: Any] }
    }

    // MARK: - Approvals

    func testApprovalCardArrivesAndAllowGoesToTheHost() async throws {
        let gateway = try await connected()
        host.ask(profile: "bruce", card: approvalCard(), role: "approval", text: "Wants to run: rm -rf ./build")
        let arrived = await waitUntil { gateway.openPrompt(for: "bruce") != nil }
        XCTAssertTrue(arrived)
        let entry = try XCTUnwrap(gateway.timeline.entries.first { $0.card != nil })
        XCTAssertEqual(entry.role, .prompt)
        XCTAssertEqual(entry.card?.command, "rm -rf ./build")
        XCTAssertEqual(entry.card?.choices, ["once", "session", "always", "deny"])
        XCTAssertTrue(gateway.hasUnread("bruce"), "a card counts as unread")

        let status = try await gateway.answerApproval(try XCTUnwrap(entry.card), in: "bruce", choice: "once")
        XCTAssertEqual(status, "allowed_once")
        XCTAssertEqual(responses().first?["choice"] as? String, "once")
        XCTAssertEqual(host.received(type: "prompt.respond").first?["profile_id"] as? String, "bruce")
        let settled = await waitUntil { gateway.timeline.entries.first { $0.card != nil }?.card?.status == "allowed_once" }
        XCTAssertTrue(settled)
        XCTAssertNil(gateway.openPrompt(for: "bruce"))
    }

    func testDenyCarriesTheReason() async throws {
        let gateway = try await connected()
        host.ask(profile: "bruce", card: approvalCard(), role: "approval", text: "x")
        _ = await waitUntil { gateway.openPrompt(for: "bruce") != nil }
        let card = try XCTUnwrap(gateway.openPrompt(for: "bruce"))
        try await gateway.answerApproval(card, in: "bruce", choice: "deny", reason: "not now")
        XCTAssertEqual(responses().first?["reason"] as? String, "not now")
        let denied = await waitUntil { gateway.timeline.entries.first { $0.card != nil }?.card?.reason == "not now" }
        XCTAssertTrue(denied)
    }

    func testAnswerOnAnotherPhoneUpdatesThisOne() async throws {
        let gateway = try await connected()
        let seq = host.ask(profile: "bruce", card: approvalCard(), role: "approval", text: "x")
        _ = await waitUntil { gateway.openPrompt(for: "bruce") != nil }
        host.updateCard(seq: seq, ["status": "denied"])
        let closed = await waitUntil { gateway.openPrompt(for: "bruce") == nil }
        XCTAssertTrue(closed)
        XCTAssertEqual(gateway.timeline.entries.filter { $0.card != nil }.count, 1, "updated in place")
    }

    func testExpiredHostAnswerIsShown() async throws {
        host.respondStatusOverride = "expired"
        let gateway = try await connected()
        host.ask(profile: "bruce", card: approvalCard(), role: "approval", text: "x")
        _ = await waitUntil { gateway.openPrompt(for: "bruce") != nil }
        let status = try await gateway.answerApproval(try XCTUnwrap(gateway.openPrompt(for: "bruce")), in: "bruce", choice: "once")
        XCTAssertEqual(status, "expired")
        XCTAssertEqual(gateway.timeline.entries.first { $0.card != nil }?.card?.status, "expired")
    }

    func testCardPastItsDeadlineIsNoLongerOpen() async throws {
        let gateway = try await connected()
        host.ask(profile: "bruce", card: approvalCard(expiresIn: 1), role: "approval", text: "x")
        _ = await waitUntil { gateway.timeline.entries.contains { $0.card != nil } }
        let card = try XCTUnwrap(gateway.timeline.entries.first { $0.card != nil }?.card)
        XCTAssertTrue(card.isOpen())
        XCTAssertFalse(card.isOpen(now: Date().addingTimeInterval(5)))
        XCTAssertNil(gateway.openPrompt(for: "bruce", now: Date().addingTimeInterval(5)))
        XCTAssertEqual(LKPromptText.outcome(of: card, now: Date().addingTimeInterval(5)).text, "Timed out — nothing ran")
    }

    // MARK: - Questions

    func testQuestionAnswers() async throws {
        let gateway = try await connected()
        host.ask(profile: "bruce", card: questionCard(), role: "question", text: "Asks: Which venue?")
        _ = await waitUntil { gateway.openPrompt(for: "bruce") != nil }
        let card = try XCTUnwrap(gateway.openPrompt(for: "bruce"))
        XCTAssertEqual(card.kind, .question)
        XCTAssertEqual(LKPromptText.attention(for: card), "Has a question")
        try await gateway.answerQuestion(card, in: "bruce", answers: ["Kemuri"])
        XCTAssertEqual(responses().first?["answers"] as? [String], ["Kemuri"])
        let answered = await waitUntil { gateway.timeline.entries.first { $0.card != nil }?.card?.answer == "Kemuri" }
        XCTAssertTrue(answered)

        host.ask(profile: "bruce", card: questionCard(id: "c_q2"), role: "question", text: "Asks: Which venue?")
        _ = await waitUntil { gateway.openPrompt(for: "bruce") != nil }
        try await gateway.answerQuestion(try XCTUnwrap(gateway.openPrompt(for: "bruce")), in: "bruce", text: "Somewhere quiet")
        XCTAssertEqual(responses().last?["text"] as? String, "Somewhere quiet")
    }

    func testUnknownCardIsAnError() async throws {
        let gateway = try await connected()
        let bogus = PromptCard(kind: .approval, id: "c_nope", choices: ["once", "deny"])
        do {
            try await gateway.answerApproval(bogus, in: "bruce", choice: "once")
            XCTFail("expected an error")
        } catch let error as HostError {
            XCTAssertEqual(error.code, "UNKNOWN_CARD")
        }
    }

    // MARK: - Slash-command confirmations

    func testConfirmationCard() async throws {
        let gateway = try await connected()
        host.ask(profile: "bruce", card: ["kind": "confirm", "id": "c_f1", "status": "pending", "title": "Confirm /new",
                                          "description": "This starts a fresh session.",
                                          "choices": ["once", "always", "cancel"]],
                 role: "confirm", text: "Confirm /new")
        _ = await waitUntil { gateway.openPrompt(for: "bruce") != nil }
        let card = try XCTUnwrap(gateway.openPrompt(for: "bruce"))
        XCTAssertEqual(card.kind, .confirm)
        XCTAssertEqual(card.title, "Confirm /new")
        XCTAssertEqual(LKPromptText.attention(for: card), "Needs your confirmation")
        let status = try await gateway.answerApproval(card, in: "bruce", choice: "cancel")
        XCTAssertEqual(status, "cancelled")
        XCTAssertEqual(LKPromptText.outcome(of: PromptCard(kind: .confirm, id: "x", status: "confirmed_once")).text, "Approved")
    }

    // MARK: - Pickers

    private func modelCard(warn: String? = nil) -> [String: Any] {
        var card: [String: Any] = [
            "kind": "model", "id": "c_m1", "status": "pending", "current_model": "claude-opus-5-5",
            "current_provider": "anthropic",
            "providers": [["slug": "anthropic", "name": "Anthropic", "models": ["claude-opus-5-5", "claude-sonnet-5-5"],
                           "is_current": true, "total_models": 2],
                          ["slug": "openrouter", "name": "OpenRouter", "models": ["x/fast-1"], "is_current": false,
                           "total_models": 120, "model_labels": ["x/fast-1": "Free"]]]]
        if let warn { card["warn"] = warn }
        return card
    }

    func testModelPicker() async throws {
        let gateway = try await connected()
        host.ask(profile: "bruce", card: modelCard(), role: "model", text: "Choose a model")
        _ = await waitUntil { gateway.timeline.entries.contains { $0.card?.kind == .model } }
        let card = try XCTUnwrap(gateway.timeline.entries.first { $0.card?.kind == .model }?.card)
        XCTAssertEqual(card.providers?.count, 2)
        XCTAssertEqual(card.providers?[1].modelLabels?["x/fast-1"], "Free")
        XCTAssertEqual(card.providers?[1].totalModels, 120)
        XCTAssertNil(gateway.openPrompt(for: "bruce"), "a picker you opened isn't 'waiting on you'")
        let (status, _) = try await gateway.pickModel(card, in: "bruce", model: "claude-sonnet-5-5", provider: "anthropic")
        XCTAssertEqual(status, "chosen")
        let switched = await waitUntil { gateway.timeline.entries.first { $0.card?.kind == .model }?.card?.chosen?.model == "claude-sonnet-5-5" }
        XCTAssertTrue(switched)
        let settled = try XCTUnwrap(gateway.timeline.entries.first { $0.card?.kind == .model }?.card)
        XCTAssertEqual(LKPromptText.outcome(of: settled).text, "Switched to claude-sonnet-5-5\non anthropic")
    }

    func testModelForThisChatOrAsTheDefault() async throws {
        let gateway = try await connected()
        host.ask(profile: "bruce", card: modelCard(), role: "model", text: "x")
        _ = await waitUntil { gateway.timeline.entries.contains { $0.card?.kind == .model } }
        let card = try XCTUnwrap(gateway.timeline.entries.first { $0.card?.kind == .model }?.card)
        _ = try await gateway.pickModel(card, in: "bruce", model: "claude-sonnet-5-5", provider: "anthropic", scope: "global")
        XCTAssertEqual(responses().last?["scope"] as? String, "global")
        let settled = await waitUntil { gateway.timeline.entries.first { $0.card?.kind == .model }?.card?.chosen?.scope == "global" }
        XCTAssertTrue(settled)
        let done = try XCTUnwrap(gateway.timeline.entries.first { $0.card?.kind == .model }?.card)
        XCTAssertEqual(LKPromptText.outcome(of: done, agentName: "Bruce").text, "Switched to claude-sonnet-5-5\non anthropic · always for Bruce")
    }

    func testExpensiveModelNeedsConfirming() async throws {
        let gateway = try await connected()
        host.ask(profile: "bruce", card: modelCard(warn: "Costs $75 per million tokens."), role: "model", text: "x")
        _ = await waitUntil { gateway.timeline.entries.contains { $0.card?.kind == .model } }
        let card = try XCTUnwrap(gateway.timeline.entries.first { $0.card?.kind == .model }?.card)
        let first = try await gateway.pickModel(card, in: "bruce", model: "claude-opus-5-5", provider: "anthropic")
        XCTAssertEqual(first.status, "needs_confirmation")
        XCTAssertEqual(first.message, "Costs $75 per million tokens.")
        XCTAssertEqual(gateway.timeline.entries.first { $0.card?.kind == .model }?.card?.status, "pending", "not switched yet")
        let second = try await gateway.pickModel(card, in: "bruce", model: "claude-opus-5-5", provider: "anthropic", confirmed: true)
        XCTAssertEqual(second.status, "chosen")
        XCTAssertEqual(responses().last?["confirmed"] as? Bool, true)
    }

    func testChoicePicker() async throws {
        let gateway = try await connected()
        host.ask(profile: "bruce", card: ["kind": "choice", "id": "c_r1", "status": "pending", "title": "**Reasoning**: medium",
                                          "options": [["value": "low", "label": "Low", "is_current": false],
                                                      ["value": "medium", "label": "Medium", "is_current": true]]],
                 role: "choice", text: "Reasoning")
        _ = await waitUntil { gateway.timeline.entries.contains { $0.card?.kind == .choice } }
        let card = try XCTUnwrap(gateway.timeline.entries.first { $0.card?.kind == .choice }?.card)
        XCTAssertEqual(card.options?.first { $0.isCurrent }?.value, "medium")
        let status = try await gateway.answerApproval(card, in: "bruce", choice: "low")
        XCTAssertEqual(status, "chosen")
        let chose = await waitUntil { gateway.timeline.entries.first { $0.card?.kind == .choice }?.card?.answer == "Low" }
        XCTAssertTrue(chose)
    }

    func testModelButtonSendsSlashModel() async throws {
        let gateway = try await connected()
        await gateway.openModelPicker()
        let sent = await waitUntil {
            (self.host.received(type: "chat.send").last?["data"] as? [String: Any])?["text"] as? String == "/model"
        }
        XCTAssertTrue(sent)
    }

    // MARK: - Cache and decoding

    func testCardsSurviveTheCache() throws {
        var timeline = ChatTimeline()
        let card = PromptCard(kind: .question, id: "c_q", question: "Which?", multiSelect: true, choices: ["A", "B"])
        timeline.applyIncoming(seq: 3, profileId: "bruce", role: "question", text: "Asks: Which?", card: card)
        let restored = try JSONDecoder().decode([ChatEntry].self, from: JSONEncoder().encode(timeline.entries))
        XCTAssertEqual(restored.first?.card, card)
        XCTAssertEqual(restored.first?.role, .prompt)
    }

    func testCardDecodesFromTheWire() throws {
        let json = #"{"seq":5,"role":"approval","text":"Wants to run: ls","rev":50,"card":{"kind":"approval","id":"c1","status":"pending","command":"ls","description":"why","choices":["once","deny"],"smart_denied":true,"expires_at":"2026-11-08T23:15:00Z"}}"#
        let message = try JSONDecoder().decode(ChatMessageData.self, from: Data(json.utf8))
        XCTAssertEqual(message.card?.smartDenied, true)
        XCTAssertEqual(message.card?.choices, ["once", "deny"])
        XCTAssertEqual(message.card?.expiryDate, try Date("2026-11-08T23:15:00Z", strategy: .iso8601))
    }

    func testOutcomeWording() {
        func card(_ status: String, reason: String? = nil, answer: String? = nil) -> PromptCard {
            PromptCard(kind: status == "answered" ? .question : .approval, id: "x", status: status,
                       reason: reason, answer: answer)
        }
        XCTAssertEqual(LKPromptText.outcome(of: card("allowed_session")).text, "Allowed for this chat")
        XCTAssertEqual(LKPromptText.outcome(of: card("denied", reason: "no")).text, "Denied — no")
        XCTAssertEqual(LKPromptText.outcome(of: card("answered", answer: "Kemuri")).text, "You answered: Kemuri")
        XCTAssertEqual(LKPromptText.timeLeft(until: Date().addingTimeInterval(272.2)), "4:33 left")
    }
}
