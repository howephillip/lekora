import XCTest
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
}
