import XCTest
@testable import Lekora

/// Schedules (docs/scheduler.md).
final class ScheduleTests: XCTestCase {
    private let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private let en = Locale(identifier: "en_US")

    func testPickersMakeHermesSchedules() {
        XCTAssertEqual(ScheduleWords.Choice.every(minutes: 120).hermesSchedule(), "every 2h")
        XCTAssertEqual(ScheduleWords.Choice.every(minutes: 15).hermesSchedule(), "every 15m")
        XCTAssertEqual(ScheduleWords.Choice.daily(hour: 7, minute: 30).hermesSchedule(), "30 7 * * *")
        XCTAssertEqual(ScheduleWords.Choice.weekdays(hour: 9, minute: 0).hermesSchedule(), "0 9 * * 1-5")
        XCTAssertEqual(ScheduleWords.Choice.days([4, 1], hour: 8, minute: 5).hermesSchedule(), "5 8 * * 1,4")
        XCTAssertEqual(ScheduleWords.Choice.monthly(day: 1, hour: 9, minute: 0).hermesSchedule(), "0 9 1 * *")
        let date = utc.date(from: DateComponents(year: 2026, month: 12, day: 1, hour: 9, minute: 0))!
        XCTAssertEqual(ScheduleWords.Choice.once(date).hermesSchedule(calendar: utc), "2026-12-01T09:00")
    }

    func testHermesSchedulesReadBackAsPickers() {
        XCTAssertEqual(ScheduleWords.choice(for: ScheduleWhen(kind: "interval", display: "every 120m", minutes: 120)), .every(minutes: 120))
        XCTAssertEqual(ScheduleWords.choice(for: ScheduleWhen(kind: "cron", display: "0 6 * * *", expr: "0 6 * * *")), .daily(hour: 6, minute: 0))
        XCTAssertEqual(ScheduleWords.choice(for: ScheduleWhen(kind: "cron", display: "x", expr: "0 9 * * 1-5")), .weekdays(hour: 9, minute: 0))
        XCTAssertEqual(ScheduleWords.choice(for: ScheduleWhen(kind: "cron", display: "x", expr: "0 7 * * 0")), .days([0], hour: 7, minute: 0))
        XCTAssertEqual(ScheduleWords.choice(for: ScheduleWhen(kind: "cron", display: "x", expr: "0 7 * * 7")), .days([0], hour: 7, minute: 0),
                       "7 is Sunday too")
        XCTAssertEqual(ScheduleWords.choice(for: ScheduleWhen(kind: "cron", display: "x", expr: "15 9 1 * *")), .monthly(day: 1, hour: 9, minute: 15))
        XCTAssertNil(ScheduleWords.choice(for: ScheduleWhen(kind: "cron", display: "x", expr: "*/5 9-17 * * 1-5")), "edited as words")
        XCTAssertEqual(ScheduleWords.text(for: ScheduleWhen(kind: "cron", display: "x", expr: "*/5 9-17 * * 1-5")), "*/5 9-17 * * 1-5")
        XCTAssertEqual(ScheduleWords.text(for: ScheduleWhen(kind: "interval", display: "every 120m", minutes: 120)), "every 2h")
    }

    func testSchedulesInPlainWords() {
        func say(_ when: ScheduleWhen) -> String { ScheduleWords.describe(when, calendar: utc, locale: en) }
        XCTAssertEqual(say(ScheduleWhen(kind: "interval", display: "every 120m", minutes: 120)), "Every 2 hours")
        XCTAssertEqual(say(ScheduleWhen(kind: "interval", display: "every 60m", minutes: 60)), "Every hour")
        XCTAssertEqual(say(ScheduleWhen(kind: "interval", display: "every 5m", minutes: 5)), "Every 5 minutes")
        XCTAssertEqual(say(ScheduleWhen(kind: "cron", display: "0 6 * * *", expr: "0 6 * * *")), "Every day at 6:00\u{202F}AM")
        XCTAssertEqual(say(ScheduleWhen(kind: "cron", display: "x", expr: "0 9 * * 1-5")), "Weekdays at 9:00\u{202F}AM")
        XCTAssertEqual(say(ScheduleWhen(kind: "cron", display: "x", expr: "30 8 * * 1,4")), "Mondays and Thursdays at 8:30\u{202F}AM")
        XCTAssertEqual(say(ScheduleWhen(kind: "cron", display: "x", expr: "0 9 1 * *")), "Monthly on the 1st at 9:00\u{202F}AM")
        XCTAssertEqual(say(ScheduleWhen(kind: "cron", display: "*/5 9-17 * * 1-5", expr: "*/5 9-17 * * 1-5")), "*/5 9-17 * * 1-5",
                       "anything else: as Hermes says it")
        XCTAssertEqual(ScheduleWords.destination("lekora:carl"), "Lekora chat")
        XCTAssertEqual(ScheduleWords.destination("local"), "Kept on the instance")
        XCTAssertEqual(ScheduleWords.destination("telegram:-1003903675131:174"), "Telegram")
        XCTAssertNotNil(ScheduleWords.date(from: "2026-11-17T19:11:42.119047-06:00"), "Hermes' times, with fractions")
        XCTAssertNotNil(ScheduleWords.date(from: "2026-11-18T06:00:00-06:00"))
    }

    func testNextTimes() {
        let first = Date(timeIntervalSince1970: 1_794_960_000)
        let every2h = ScheduleWhen(kind: "interval", display: "every 120m", minutes: 120)
        XCTAssertEqual(ScheduleWords.nextTimes(every2h, first: first, preview: [first.addingTimeInterval(60)]),
                       [first, first.addingTimeInterval(7200), first.addingTimeInterval(14_400)],
                       "counted on from Hermes' next run, not from when the page opened")
        let once = ScheduleWhen(kind: "once", display: "once", run_at: "x")
        XCTAssertEqual(ScheduleWords.nextTimes(once, first: first, preview: []), [first])
        let cron = ScheduleWhen(kind: "cron", display: "x", expr: "0 9 * * *")
        let later = [first, first.addingTimeInterval(86_400), first.addingTimeInterval(172_800)]
        XCTAssertEqual(ScheduleWords.nextTimes(cron, first: first, preview: later), later, "no doubles")
        XCTAssertEqual(ScheduleWords.upcoming(first, now: first.addingTimeInterval(600)), "due now", "never “Next 10 minutes ago”")
    }

    func testChangesSayOnlyWhatChanged() throws {
        var changes = ScheduleChanges(name: "Morning")
        changes.repeatTimes = .some(nil)
        changes.model = .some(nil)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(changes)) as? [String: Any]
        XCTAssertEqual(json?["name"] as? String, "Morning")
        XCTAssertTrue(json?["repeat"] is NSNull, "forever, said on purpose")
        XCTAssertTrue(json?["model"] is NSNull, "the agent's own model, said on purpose")
        XCTAssertNil(json?["prompt"], "unchanged parts aren't sent")
        XCTAssertTrue(ScheduleChanges().isEmpty)
    }

    @MainActor
    func testEveryActionAgainstTheInstance() async throws {
        let host = try FakeHost()
        host.profiles = [["profile_id": "default", "name": "Default", "avatar": "sparkles"],
                         ["profile_id": "carl", "name": "Carl", "avatar": "sparkles"]]
        try await host.start()
        defer { host.stop() }
        let store = InMemoryCredentialStore()
        try SavedHost(instanceId: host.instanceId, instanceName: host.instanceName, deviceId: "dev_1",
                      deviceToken: host.acceptedDeviceToken, endpoints: [host.endpoint],
                      enabledProfileIds: ["default"], activeProfileId: "default").save(to: store)
        let gateway = GatewayClient(keychain: store, requireTLS: false)
        await gateway.resumeSavedSession()

        let preview = try await gateway.previewSchedule("0 9 * * 1-5")
        XCTAssertEqual(preview.next.count, 2)
        do {
            _ = try await gateway.previewSchedule("whenever")
            XCTFail("Hermes can't read that")
        } catch let error as HostError {
            XCTAssertEqual(error.code, "INVALID_SCHEDULE")
            XCTAssertTrue(error.localizedDescription.contains("every 30m"), "Hermes' hint is shown")
        }

        let draft = try await gateway.draftSchedule("every weekday at 8, my inbox", for: "carl")
        XCTAssertEqual(draft.name, "Morning inbox")
        XCTAssertEqual(ScheduleWords.choice(for: draft.preview.when), .weekdays(hour: 8, minute: 0), "a draft fills the pickers")
        XCTAssertEqual(host.received.last { $0["type"] as? String == "schedule.draft" }?["profile_id"] as? String, "carl")

        let made = try await gateway.createSchedule(ScheduleCreateData(name: "Morning", prompt: "Summarise my inbox",
                                                                      schedule: "0 9 * * 1-5", deliver: "lekora"), for: "carl")
        XCTAssertEqual(made.deliver, "lekora:carl")
        XCTAssertEqual(ScheduleWords.destination(made.deliver), "Lekora chat")
        let all = try await gateway.schedules()
        XCTAssertEqual(all.map(\.profile_id), ["carl"], "every agent's, from the menu")
        let carls = try await gateway.schedules(for: "carl")
        XCTAssertEqual(carls.first?.title, "Morning")

        var changes = ScheduleChanges(schedule: "every 2h")
        changes.repeatTimes = .some(3)
        let edited = try await gateway.updateSchedule(made.id, changes, for: "carl")
        XCTAssertEqual(edited.schedule.minutes, 120)
        XCTAssertEqual(edited.repeat.times, 3)

        let paused = try await gateway.scheduleAction("pause", made.id, for: "carl")
        XCTAssertTrue(paused.isPaused)
        do {
            _ = try await gateway.scheduleAction("run", made.id, for: "carl")
            XCTFail("a paused schedule isn't run")
        } catch let error as HostError {
            XCTAssertEqual(error.code, "SCHEDULE_REFUSED")
        }
        let resumed = try await gateway.scheduleAction("resume", made.id, for: "carl")
        XCTAssertFalse(resumed.isPaused)
        try await gateway.scheduleAction("run", made.id, for: "carl")

        let runs = try await gateway.scheduleRuns(made.id, for: "carl")
        XCTAssertEqual(runs.map(\.status), ["ok", "failed"])
        let output = try await gateway.scheduleOutput(made.id, run: runs[0].id, for: "carl")
        XCTAssertEqual(output, "Three new emails.")

        try await gateway.deleteSchedule(made.id, for: "carl")
        let none = try await gateway.schedules()
        XCTAssertTrue(none.isEmpty)
    }

    @MainActor
    func testChangesElsewhereAreHeard() async throws {
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
        let before = gateway.schedulesChanges
        host.sendSchedulesChanged(profile: "default")
        for _ in 0..<50 where gateway.schedulesChanges == before {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(gateway.schedulesChanges, before + 1)
        XCTAssertEqual(gateway.lastSchedulesChange, "default")
    }
}
