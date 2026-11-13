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

    func testSpokenRepliesDecodeAndCache() throws {
        let json = #"{"seq":9,"role":"assistant","text":"Hi there.","spoken":[{"file_id":"f","name":"Voice reply part 1.mp3","mime":"audio/mpeg","size":3,"kind":"audio"}]}"#
        let message = try JSONDecoder().decode(ChatMessageData.self, from: Data(json.utf8))
        var timeline = ChatTimeline()
        timeline.applyIncoming(seq: 9, profileId: "default", role: "assistant", text: message.text, spoken: message.spoken)
        let cached = try JSONDecoder().decode(ChatEntry.self, from: JSONEncoder().encode(try XCTUnwrap(timeline.entries.first)))
        XCTAssertEqual(cached.spoken?.first?.file_id, "f")
        XCTAssertEqual(cached.text, "Hi there.", "the text stays: it's the transcript")
        XCTAssertEqual(LKVoiceNames.provider("fish_audio"), "Fish Audio", "custom voices get a tidy name")
    }

    func testOlderSettingsAndVoiceRepliesDecode() throws {
        let old = try JSONDecoder().decode(AgentVoiceSettings.self, from: Data(#"{"speak":"always","engine":"iphone","rate":0.5}"#.utf8))
        XCTAssertEqual(old.style, "tts", "hosts from before voice styles")
        XCTAssertEqual(old.style_source, "hermes")
        XCTAssertEqual(old.fillers, 1)
        let preset = try JSONDecoder().decode(AgentVoiceSettings.self, from: Data(
            #"{"speak":"always","style":"personality","style_source":"preset","style_preset":"hype","fillers":2,"pauses":0,"pace":2}"#.utf8))
        XCTAssertEqual(preset.style_preset, "hype")
        XCTAssertEqual(preset.pace, 2)
        let json = #"{"seq":3,"role":"assistant","text":"Hi.","voicing":"personality","voice_key":"reply-1","voice_problem":"no ffmpeg"}"#
        let message = try JSONDecoder().decode(ChatMessageData.self, from: Data(json.utf8))
        var timeline = ChatTimeline()
        timeline.applyIncoming(seq: 3, profileId: "default", role: "assistant", text: message.text,
                               voicing: message.voicing, voiceProblem: message.voice_problem, voiceKey: message.voice_key)
        let entry = try XCTUnwrap(timeline.entries.first)
        XCTAssertEqual(entry.voicing, "personality")
        XCTAssertEqual(entry.voiceKey, "reply-1")
        XCTAssertEqual(entry.voiceProblem, "no ffmpeg")
        let said = try JSONDecoder().decode(ChatMessageData.self, from: Data(
            #"{"seq":4,"role":"assistant","text":"Newton's first law.","voicing":"personality","spoken_text":"So, uh, Newton's first law… [laughs]"}"#.utf8))
        timeline.applyIncoming(seq: 4, profileId: "default", role: "assistant", text: said.text,
                               voicing: said.voicing, spokenText: said.spoken_text)
        XCTAssertEqual(timeline.entries.last?.spokenText, "So, uh, Newton's first law… [laughs]", "what you hear")
        XCTAssertEqual(timeline.entries.last?.text, "Newton's first law.", "what was written")
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

        let urls = try await gateway.hermesSpeech(for: 1, in: "default")
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(urls.first)), Data("ID3 speech 1".utf8))

        // Voice mode: parts of a reply arrive while it's spoken, then the saved reply carries them.
        let part = host.storeFile(Data("ID3 part".utf8), name: "Voice reply part 1.mp3", mime: "audio/mpeg")
        host.sendVoiceSegment(messageId: "live-1", index: 0, file: part, profile: "default")
        let live = await waitUntil { gateway.liveSpeech["live-1"]?.count == 1 }
        XCTAssertTrue(live)
        host.sendVoiceSegment(messageId: "live-1", index: 0, file: part, profile: "default")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(gateway.liveSpeech["live-1"]?.count, 1, "the same part only once")

        try await gateway.setVoiceReplies("always", for: "default")
        XCTAssertEqual(host.voiceSettings["speak"] as? String, "always")

        // The instance says a reply is a voice note before any audio; then why it can't play.
        host.sendVoiceReply(messageId: "live-2", style: "personality", profile: "default")
        let told = await waitUntil { gateway.voiceReplies["live-2"]?.style == "personality" }
        XCTAssertTrue(told)
        host.sendVoiceReply(messageId: "live-2", style: "personality", problem: "iPhone can't play OGG", profile: "default")
        let problem = await waitUntil { gateway.voiceReplies["live-2"]?.problem != nil }
        XCTAssertTrue(problem)

        // Tools in Lekora chats.
        var tools = try await gateway.agentTools(for: "default")
        XCTAssertEqual(tools.toolsets.first { $0.key == "kanban" }?.enabled, false)
        XCTAssertEqual(tools.elsewhere?["telegram"], ["file", "kanban", "web"])
        tools = try await gateway.setAgentTools(["kanban": true], for: "default")
        XCTAssertEqual(tools.toolsets.first { $0.key == "kanban" }?.enabled, true)
    }
}
