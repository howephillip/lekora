import XCTest
@testable import Lekora

/// Voice notes (docs/voice.md).
@MainActor
final class VoiceNoteTests: XCTestCase {
    func testSendingAVoiceNoteAndItsTranscript() async throws {
        let host = try FakeHost()
        host.profiles = [["profile_id": "default", "name": "Default", "avatar": "sparkles"]]
        host.history = []
        try await host.start()
        defer { host.stop() }
        let store = InMemoryCredentialStore()
        try SavedHost(instanceId: host.instanceId, instanceName: host.instanceName, deviceId: "dev_1",
                      deviceToken: host.acceptedDeviceToken, endpoints: [host.endpoint],
                      enabledProfileIds: ["default"], activeProfileId: "default").save(to: store)
        let gateway = GatewayClient(keychain: store, requireTLS: false)
        gateway.fileCacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent("lk-voice-\(UUID().uuidString)")
        await gateway.resumeSavedSession()

        let recording = FileManager.default.temporaryDirectory.appendingPathComponent("Voice note test.m4a")
        try Data("aac audio".utf8).write(to: recording)
        try await gateway.sendVoiceNote(at: recording, duration: 3.4, waveform: [0.2, 0.9, 0.4])

        let sent = await waitUntil { host.sentVoice.count == 1 }
        XCTAssertTrue(sent)
        XCTAssertEqual(host.sentVoice.first?["duration"] as? Double, 3.4)
        XCTAssertEqual(host.storedFiles["f_1"]?.meta["mime"] as? String, "audio/mp4")

        let saved = await waitUntil { gateway.timeline.entries(for: "default").first?.seq != nil }
        XCTAssertTrue(saved)
        let entry = try XCTUnwrap(gateway.timeline.entries(for: "default").first)
        XCTAssertEqual(entry.voice, VoiceDetails(duration: 3.4, waveform: [0.2, 0.9, 0.4]))
        XCTAssertNotNil(gateway.cachedFileURL(try XCTUnwrap(entry.files?.first)), "plays straight away")

        host.transcribe(seq: try XCTUnwrap(entry.seq), "Book ramen for two")
        let heard = await waitUntil { gateway.timeline.entries(for: "default").first?.transcript == "Book ramen for two" }
        XCTAssertTrue(heard, "shown under the voice bubble")
        XCTAssertEqual(gateway.timeline.entries(for: "default").count, 2, "the note and the agent's reply, no extra line")
    }

    func testVoiceDetailsDecodeAndCache() throws {
        let json = #"{"seq":4,"role":"user","text":"","files":[{"file_id":"f","name":"v.m4a","mime":"audio/mp4","size":9,"kind":"audio"}],"voice":{"duration":2.5,"waveform":[0.1,0.5]},"transcript":"hi"}"#
        let message = try JSONDecoder().decode(ChatMessageData.self, from: Data(json.utf8))
        XCTAssertEqual(message.voice?.duration, 2.5)
        XCTAssertEqual(message.transcript, "hi")
        var timeline = ChatTimeline()
        timeline.applyIncoming(seq: 4, profileId: "default", role: "user", text: "", files: message.files,
                               voice: message.voice, transcript: message.transcript)
        let entry = try XCTUnwrap(timeline.entries.first)
        let cached = try JSONDecoder().decode(ChatEntry.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(cached.voice, message.voice)
        XCTAssertEqual(cached.transcript, "hi")
    }

    func testWaveformBars() {
        XCTAssertEqual(VoiceWaveform.bars([0.1, 0.2], count: 48), [0.1, 0.2], "short recordings keep every level")
        let bars = VoiceWaveform.bars((0..<480).map { Double($0 % 10) / 10 }, count: 48)
        XCTAssertEqual(bars.count, 48)
        XCTAssertEqual(bars.max(), 0.9, "each bar is its slice's loudest")
        XCTAssertEqual(VoiceWaveform.level(fromDecibels: -80), 0.02)
        XCTAssertEqual(VoiceWaveform.level(fromDecibels: 0), 1)
        XCTAssertEqual(LKVoiceText.duration(83), "1:23")
    }
}
