import XCTest
import AVFoundation
@testable import Lekora

/// Hearing replies (docs/voice.md §2).
@MainActor
final class HearingRepliesTests: XCTestCase {
    func testSentencesAreSpokenAsTheyArrive() {
        var spoken = 0
        var said: [String] = []
        func feed(_ text: String, final: Bool = false) {
            let next = SpeechText.nextChunks(in: text, after: spoken, final: final)
            said += next.chunks
            spoken = next.spoken
        }
        feed("Sure! I booked")
        XCTAssertEqual(said, ["Sure!"], "a finished sentence goes straight away")
        feed("Sure! I booked ramen for two at 7")
        XCTAssertEqual(said, ["Sure!"], "the second isn't finished yet")
        feed("Sure! I booked ramen for two at 7. See you")
        XCTAssertEqual(said, ["Sure!", "I booked ramen for two at 7."])
        feed("Sure! I booked ramen for two at 7. See you there", final: true)
        XCTAssertEqual(said.last, "See you there", "the rest once the reply is done")
        feed("Sure! I booked ramen for two at 7. See you there", final: true)
        XCTAssertEqual(said.count, 3, "nothing twice")
    }

    func testCodeAndMarkdownAreCleaned() {
        XCTAssertEqual(SpeechText.clean("**Bold** and `code`, [the site](https://x.com)"), "Bold and code, the site")
        XCTAssertEqual(SpeechText.clean("## Plan\n- one\n- two"), "Plan one two")
        XCTAssertEqual(SpeechText.clean("Run this:\n```\nls -la. rm x\n```\nDone."), "Run this: Done.")
        let chunks = SpeechText.nextChunks(in: "Look:\n```\na. b. c\n", after: 0, final: false).chunks
        XCTAssertEqual(chunks, ["Look:"], "an open code block isn't split into sentences")
    }

    func testRates() {
        XCTAssertEqual(ReplySpeaker.rate(0.5), AVSpeechUtteranceDefaultSpeechRate)
        XCTAssertLessThan(ReplySpeaker.rate(0.2), ReplySpeaker.rate(0.5))
        XCTAssertGreaterThan(ReplySpeaker.rate(0.8), ReplySpeaker.rate(0.5))
    }

    func testSettingsLoadSaveAndFollowOtherPhones() async throws {
        let host = try FakeHost()
        host.profiles = [["profile_id": "default", "name": "Default", "avatar": "sparkles"]]
        host.history = [(1, "assistant", "Ramen at 7?", "default")]
        try await host.start()
        defer { host.stop() }
        let store = InMemoryCredentialStore()
        try SavedHost(instanceId: host.instanceId, instanceName: host.instanceName, deviceId: "dev_1",
                      deviceToken: host.acceptedDeviceToken, endpoints: [host.endpoint],
                      enabledProfileIds: ["default"], activeProfileId: "default").save(to: store)
        let gateway = GatewayClient(keychain: store, requireTLS: false)
        gateway.fileCacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent("lk-hear-\(UUID().uuidString)")
        await gateway.resumeSavedSession()

        await gateway.loadVoiceSettings(for: "default")
        XCTAssertEqual(gateway.voiceSettings["default"], .standard)
        XCTAssertEqual(gateway.hermesVoice["default"]?.available, true)

        try await gateway.setVoiceSettings(AgentVoiceSettings(speak: "always", voice: "com.apple.voice.premium.en-US.Zoe", rate: 0.6),
                                           for: "default")
        XCTAssertEqual(host.voiceSettings["speak"] as? String, "always", "saved on the instance")
        XCTAssertEqual(gateway.voiceSettings["default"]?.voice, "com.apple.voice.premium.en-US.Zoe")

        host.changeVoiceElsewhere(["speak": "voice_notes", "engine": "hermes", "rate": 0.5], profile: "default")
        let followed = await waitUntil { gateway.voiceSettings["default"]?.speak == "voice_notes" }
        XCTAssertTrue(followed)

        let url = try await gateway.hermesSpeech(for: 1, in: "default")
        XCTAssertEqual(try Data(contentsOf: url), Data("ID3 speech 1".utf8))
    }
}
