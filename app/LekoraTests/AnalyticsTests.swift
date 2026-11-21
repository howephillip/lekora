import XCTest
@testable import Lekora

/// Analytics (docs/analytics.md).
@MainActor
final class AnalyticsTests: XCTestCase {
    private var host: FakeHost!

    override func setUp() async throws {
        host = try FakeHost()
        host.profiles = [["profile_id": "default", "name": "Home", "avatar": "sparkles"],
                         ["profile_id": "coder", "name": "Coder", "avatar": "sparkles"]]
        host.history = [(1, "assistant", "Hi", "default")]
        try await host.start()
    }

    override func tearDown() async throws {
        host.stop()
        host = nil
    }

    private func connected() async throws -> GatewayClient {
        let store = InMemoryCredentialStore()
        try SavedHost(instanceId: host.instanceId, instanceName: host.instanceName, deviceId: "dev_1",
                      deviceToken: host.acceptedDeviceToken, endpoints: [host.endpoint],
                      enabledProfileIds: ["default", "coder"], activeProfileId: "default").save(to: store)
        let gateway = GatewayClient(keychain: store, requireTLS: false)
        await gateway.resumeSavedSession()
        _ = await waitUntil { !gateway.timeline.entries.isEmpty }
        return gateway
    }

    func testAReportArrives() async throws {
        let gateway = try await connected()
        let report = try await gateway.analytics(days: 7)
        XCTAssertEqual(report.totals.sessions, 669)
        XCTAssertEqual(report.daily.count, 7)
        XCTAssertNotNil(report.daily.first?.date)
        XCTAssertEqual(report.by_agent.first?.profile_id, "coder")
        XCTAssertEqual(report.accounts.first?.windows?.first?.used_percent, 17.1)
    }

    func testOneAgentsNumbersAreAskedFor() async throws {
        let gateway = try await connected()
        _ = try await gateway.analytics(days: 30, profileId: "coder")
        XCTAssertEqual(host.analyticsAsked.last?["profile_id"] as? String, "coder")
        XCTAssertEqual(host.analyticsAsked.last?["days"] as? Int, 30)
    }

    func testWords() {
        XCTAssertEqual(LKAnalyticsText.money(35.938), "$35.94")
        XCTAssertEqual(LKAnalyticsText.money(0.004), "<$0.01")
        XCTAssertEqual(LKAnalyticsText.money(0), "$0")
        XCTAssertEqual(LKAnalyticsText.money(250, short: true), "$250")
        XCTAssertEqual(LKAnalyticsText.source("kanban"), "Board workers")
        XCTAssertEqual(LKAnalyticsText.source("background"), "Background tasks")
        XCTAssertEqual(LKAnalyticsText.source("telegram"), "Telegram")
        XCTAssertEqual(LKAnalyticsText.provider("openrouter"), "OpenRouter")
        XCTAssertEqual(LKAnalyticsText.period(1), "Today")
    }

    func testADayIsThatDayOnThisPhonesClock() throws {
        let day = try JSONDecoder().decode(AnalyticsReport.Day.self, from: Data(#"{"day":"2026-11-15","cost_usd":1,"tokens":2}"#.utf8))
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: try XCTUnwrap(day.date))
        XCTAssertEqual([parts.year, parts.month, parts.day], [2026, 11, 15])
    }
}
