import XCTest
@testable import Lekora

final class RouteProberTests: XCTestCase {
    func testEmptyEndpointsThrowsError() async {
        let prober = RouteProber()
        do {
            _ = try await prober.probeFastest(endpoints: [])
            XCTFail("Expected noEndpointsProvided error")
        } catch let error as RouteProberError {
            XCTAssertEqual(error, .noEndpointsProvided)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testInvalidEndpointsThrowsError() async {
        let prober = RouteProber()
        do {
            _ = try await prober.probeFastest(endpoints: [""])
            XCTFail("Expected noEndpointsProvided error")
        } catch let error as RouteProberError {
            XCTAssertEqual(error, .noEndpointsProvided)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testUnreachableEndpointsThrowsAllEndpointsFailed() async {
        let prober = RouteProber()
        do {
            // Using reserved unroutable addresses with short timeout
            _ = try await prober.probeFastest(
                endpoints: [
                    "ws://192.0.2.1:49999",
                    "ws://198.51.100.1:49999"
                ],
                timeoutSeconds: 0.2
            )
            XCTFail("Expected allEndpointsFailed error")
        } catch let error as RouteProberError {
            XCTAssertEqual(error, .allEndpointsFailed)
        } catch {
            // Socket or POSIX errors during probe
            XCTAssertNotNil(error)
        }
    }
}
