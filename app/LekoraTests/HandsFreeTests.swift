import XCTest
import LiveKit
import AVFoundation
@testable import Lekora

/// Hands-free conversation (docs/voice.md §3).
final class HandsFreeTests: XCTestCase {
    /// Feeds `seconds` of a steady level in 20 ms readings; returns the events.
    private func feed(_ detector: inout SpeechDetector, level: Float, seconds: Double) -> [SpeechDetector.Event] {
        var events: [SpeechDetector.Event] = []
        for _ in 0..<Int(seconds / 0.02) {
            if let event = detector.feed(level: level, duration: 0.02) { events.append(event) }
        }
        return events
    }

    func testATurnStartsAndEndsWithTalkingAndQuiet() {
        var detector = SpeechDetector()
        XCTAssertEqual(feed(&detector, level: -60, seconds: 1), [], "a quiet room")
        XCTAssertEqual(feed(&detector, level: -25, seconds: 2), [.started])
        XCTAssertTrue(detector.talking)
        XCTAssertEqual(feed(&detector, level: -60, seconds: 0.8), [], "a short pause isn't the end")
        XCTAssertEqual(feed(&detector, level: -25, seconds: 1), [])
        XCTAssertEqual(feed(&detector, level: -60, seconds: 1.5), [.ended], "about a second of quiet ends the turn")
        XCTAssertFalse(detector.talking)
    }

    func testCoughsAndClicksArentTurns() {
        var detector = SpeechDetector()
        _ = feed(&detector, level: -60, seconds: 1)
        XCTAssertEqual(feed(&detector, level: -20, seconds: 0.08), [], "too short to start")
        _ = feed(&detector, level: -60, seconds: 0.5)
        XCTAssertEqual(feed(&detector, level: -20, seconds: 0.2), [.started])
        XCTAssertEqual(feed(&detector, level: -60, seconds: 1.5), [], "a blip under half a second isn't sent")
        XCTAssertFalse(detector.talking)
    }

    func testANoisyRoomRaisesTheBar() {
        var detector = SpeechDetector()
        XCTAssertEqual(feed(&detector, level: -35, seconds: 6), [], "steady background noise isn't talking")
        XCTAssertFalse(detector.talking)
        XCTAssertGreaterThan(detector.threshold, -30)
        XCTAssertEqual(feed(&detector, level: -15, seconds: 0.5), [.started], "talking over it is")
    }
}


final class HandsFreeNoiseTests: XCTestCase {
    func testNoiseThatStartsLaterStopsCountingAsTalking() {
        var detector = SpeechDetector()
        var events: [SpeechDetector.Event] = []
        for _ in 0..<50 { if let e = detector.feed(level: -60, duration: 0.02) { events.append(e) } }
        for _ in 0..<4000 { if let e = detector.feed(level: -30, duration: 0.02) { events.append(e) } }  // a fan turns on, 80 s
        XCTAssertFalse(detector.talking, "it stops counting as talking (at most one turn)")
        XCTAssertGreaterThan(detector.threshold, -30, "then it's background")
        XCTAssertEqual(events.first, .started, "at first it sounded like someone talking")
    }
}


final class HandsFreeLongTurnTests: XCTestCase {
    func testALongStretchOfTalkingIsOneTurn() {
        var detector = SpeechDetector()
        var events: [SpeechDetector.Event] = []
        for _ in 0..<50 { if let e = detector.feed(level: -60, duration: 0.02) { events.append(e) } }
        // 40 s of speech: syllables with short dips between words.
        for i in 0..<2000 {
            if let e = detector.feed(level: i % 12 < 9 ? -25 : -50, duration: 0.02) { events.append(e) }
        }
        XCTAssertEqual(events, [.started], "still the same turn after 40 seconds")
        for _ in 0..<100 { if let e = detector.feed(level: -60, duration: 0.02) { events.append(e) } }
        XCTAssertEqual(events, [.started, .ended])
    }

    // MARK: - The vibe: laughs, sighs… with the words

    func testSoundsAreWovenInWhereTheyHappened() {
        let words: [(start: Double, text: String)] = [(10.0, "that's hilarious"), (13.0, "okay so anyway")]
        let woven = SoundCue.weave(words: words, sounds: [(11.6, "[laughs]"), (12.3, "[laughs]")])
        XCTAssertEqual(woven, "that's hilarious [laughs] okay so anyway", "overlapping moments of one laugh count once")
        XCTAssertEqual(SoundCue.weave(words: words, sounds: [(9.5, "[sighs]"), (15, "[laughs]")]),
                       "[sighs] that's hilarious okay so anyway [laughs]")
        XCTAssertEqual(SoundCue.weave(words: words, sounds: []), "that's hilarious okay so anyway", "nothing heard: just the words")
    }

    func testOnlyMeaningfulSoundsBecomeTags() {
        XCTAssertEqual(SoundCue.tags["laughter"]?.tag, "[laughs]")
        XCTAssertEqual(SoundCue.tags["sigh"]?.tag, "[sighs]")
        XCTAssertNil(SoundCue.tags["cough"], "a cough isn't the vibe")
        XCTAssertNil(SoundCue.tags["car_passing_by"])
    }

    func testLaughsAndShoutsNeedLessCertaintyThanSighs() {
        XCTAssertLessThan(SoundCue.tags["laughter"]!.confidence, SoundCue.tags["sigh"]!.confidence,
                          "laughing over your words scores lower than a lone sigh")
        XCTAssertLessThan(SoundCue.tags["shout"]!.confidence, SoundCue.tags["whispering"]!.confidence)
        XCTAssertEqual(SoundCue.summary(["[sighs]": 0.2, "[laughs]": 0.41]), "[laughs] 0.41, [sighs] 0.20")
    }

    func testTheRoomIsMeasuredAgainWhenTheMicrophoneChanges() {
        var detector = SpeechDetector()
        for _ in 0..<50 { _ = detector.feed(level: -60, duration: 0.02) }
        detector.remeasure()
        var events: [SpeechDetector.Event] = []
        for _ in 0..<100 { if let e = detector.feed(level: -40, duration: 0.02) { events.append(e) } }
        XCTAssertEqual(events, [], "a louder room after the change isn't talking")
    }

    func testTheAgentsOwnVoiceLeakingBackIsntYou() {
        let agent = "Sure! I booked ramen for two at seven tonight."
        XCTAssertEqual(EchoFilter.fresh(heard: "ramen for two", agent: agent), 0, "its own words")
        XCTAssertEqual(EchoFilter.fresh(heard: "uh", agent: agent), 1, "a stray sound read as a word")
        XCTAssertGreaterThanOrEqual(EchoFilter.fresh(heard: "wait, stop, make it eight", agent: agent), 2, "you talking over it")
    }

    /// During a call only the call's own players sound (owner, 2026-11-13).
    @MainActor
    func testOtherPlayersStayQuietDuringACall() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lk-beep-\(UUID().uuidString).wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        try file.write(from: buffer)
        defer { try? FileManager.default.removeItem(at: url); AudioSessionOwner.handsFree = false }

        let chat = VoicePlayer()
        let call = VoicePlayer()
        call.belongsToCall = true
        chat.play(id: "note", url: url, from: 0)  // (whether it sounds here depends on the test machine)
        AudioSessionOwner.handsFree = true
        XCTAssertFalse(chat.isPlaying, "the call starting stops it")
        chat.play(id: "note", url: url, from: 0)
        XCTAssertFalse(chat.isPlaying, "and it can't start again during the call (e.g. a note that just loaded)")
        XCTAssertNil(chat.currentId, "nothing of the note is left to resume")
        XCTAssertTrue(call.belongsToCall)
    }

    // MARK: - Calls, polished (owner, 2026-11-22)

    /// "If it recognizes something it needs to differentiate between me speaking to it or accidentally
    /// hearing a word or two."
    func testOnlyWordsMeantForTheAgentInterruptIt() {
        let agent = "There are three options. The first is the ramen place on Fifth."
        XCTAssertFalse(Interruption.isMeant(heard: "mm-hm", agent: agent))
        XCTAssertFalse(Interruption.isMeant(heard: "yeah okay", agent: agent), "acknowledgements aren't interruptions")
        XCTAssertFalse(Interruption.isMeant(heard: "the ramen place", agent: agent), "its own voice leaking back")
        XCTAssertFalse(Interruption.isMeant(heard: "uh", agent: agent), "a stray word")
        XCTAssertTrue(Interruption.isMeant(heard: "wait", agent: agent), "a stop word pauses it at once")
        XCTAssertTrue(Interruption.isMeant(heard: "hold on", agent: agent))
        XCTAssertTrue(Interruption.isMeant(heard: "what about sushi instead", agent: agent), "real words for it")
        XCTAssertFalse(Interruption.isMeant(heard: "wait", agent: "Wait a second while I check."),
                       "its own \"wait\" leaking back isn't you")
    }

    /// "If I interrupt on something it started talking about earlier, it thinks I heard the whole thing":
    /// the app knows what has actually played, and a pause holds the rest for later.
    @MainActor
    func testWhatWasHeardIsTrackedAndAPauseHoldsTheRest() async throws {
        let speaker = StreamSpeaker()
        func tone(_ seconds: Double) -> Data {
            Data((0..<Int(seconds * 24_000)).flatMap { i -> [UInt8] in
                let v = Int16(sin(Double(i) / 10) * 3000)
                return [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8)]
            })
        }
        speaker.play(pcm: tone(0.6), rate: 24_000, piece: "r#0")
        speaker.finish(piece: "r#0", text: "There are three options.")
        speaker.flush()
        speaker.play(pcm: tone(3.0), rate: 24_000, piece: "r#1")
        speaker.finish(piece: "r#1", text: "The first is the ramen place on Fifth, which is open late tonight.")
        speaker.flush()
        let started = await waitUntil(timeout: 10) { speaker.heardText.hasPrefix("There are three options.") }
        XCTAssertTrue(started, "the first part has played")
        speaker.pause()
        let heard = speaker.heardText
        XCTAssertTrue(heard.hasPrefix("There are three options."))
        XCTAssertFalse(heard.hasSuffix("tonight."), "the second part hasn't all played")
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(speaker.heardText, heard, "nothing plays while paused")
        XCTAssertTrue(speaker.isSpeaking, "the rest is held, ready to go on")
        speaker.resume()
        let finished = await waitUntil(timeout: 10) { speaker.heardText.hasSuffix("open late tonight.") }
        XCTAssertTrue(finished, "after resuming it plays to the end")
        speaker.stop()
        XCTAssertEqual(speaker.heardText, "")
    }

    /// Silence after you speak is filled by a soft sound (owner, 2026-11-22).
    func testTheThinkingSoundIsAShortQuietLoop() throws {
        let player = try AVAudioPlayer(data: ThinkingCue.sound())
        XCTAssertEqual(player.duration, 2.4, accuracy: 0.05)
    }

    /// The words heard go with the next turn only from a call.
    func testHeardTextTravelsOnlyWithCallTurns() throws {
        let call = GatewayClient.makeChatSendEnvelope(text: "which one", instanceId: "i", profileId: "p", handsFree: true,
                                                      heard: "There are three options.")
        XCTAssertEqual(call.data.heard, "There are three options.")
        let typed = GatewayClient.makeChatSendEnvelope(text: "hi", instanceId: "i", profileId: "p", heard: "x")
        XCTAssertNil(typed.data.heard)
    }

    // MARK: - Live voice engines (docs/live-calls.md)

    /// The engine is kept per agent; GPT-Live's voice reaches the phone; the microphone's sound goes out.
    @MainActor
    func testLiveEnginesAreKeptAndGptLiveSoundFlows() async throws {
        let host = try FakeHost()
        host.profiles = [["profile_id": "default", "name": "Default", "avatar": "sparkles"]]
        try await host.start()
        defer { host.stop() }
        let store = InMemoryCredentialStore()
        try SavedHost(instanceId: host.instanceId, instanceName: host.instanceName, deviceId: "dev_1",
                      deviceToken: host.acceptedDeviceToken, endpoints: [host.endpoint],
                      enabledProfileIds: ["default"], activeProfileId: "default").save(to: store)
        let gateway = GatewayClient(keychain: store, requireTLS: false)
        await gateway.resumeSavedSession()
        var engines = try await gateway.liveEngines(for: "default")
        XCTAssertEqual(engines.engine, "agent")
        XCTAssertEqual(engines.engines.first { $0.id == "fish-live" }?.available, false)
        engines = try await gateway.setLiveEngine("gpt-live", for: "default")
        XCTAssertEqual(engines.engine, "gpt-live", "kept until changed")
        var voice: String?
        gateway.onLiveAudio = { voice = $0 }
        let started = try await gateway.startLive("gpt-live", for: "default")
        XCTAssertEqual(started.session_id, "live_1")
        let arrived = await waitUntil { voice != nil }
        XCTAssertTrue(arrived, "its voice comes back over the same connection")
        gateway.sendLiveAudio("AAAA", profileId: "default")
        let sent = await waitUntil { host.liveAudioReceived == 1 }
        XCTAssertTrue(sent, "the microphone's sound goes out with no reply expected")
        await gateway.stopLive(for: "default")
    }

    /// Fish's ask_agent tool calls arrive as data on `agent-event`; the rest is ignored.
    @MainActor
    func testFishToolCallsAreRead() async throws {
        let events = FishRoomEvents()
        var asked: (String, String)?
        var ended: String?
        events.onToolCall = { asked = ($0, $1) }
        events.onEnded = { ended = $0 }
        let room = Room()
        let call = #"{"type":"client_tool.call","callId":"call_1","toolName":"ask_agent","params":{"request":"what's on today"},"expectsResponse":true}"#
        events.room(room, participant: nil, didReceiveData: Data(call.utf8), forTopic: "agent-event", encryptionType: .none)
        events.room(room, participant: nil, didReceiveData: Data(call.utf8), forTopic: "other", encryptionType: .none)
        events.room(room, participant: nil, didReceiveData: Data(#"{"type":"session.ended","reason":"user_hangup"}"#.utf8),
                    forTopic: "agent-event", encryptionType: .none)
        let got = await waitUntil { asked != nil && ended != nil }
        XCTAssertTrue(got)
        XCTAssertEqual(asked?.0, "call_1")
        XCTAssertEqual(asked?.1, "what's on today")
        XCTAssertEqual(ended, "user_hangup")
    }
}
