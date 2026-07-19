import XCTest
@testable import MoviesConnector

final class SecurityScopedAccessTests: XCTestCase {
    override func tearDown() {
        SecurityScopedAccess.resetAccessorsForTesting()
        super.tearDown()
    }

    func testAsyncOverloadKeepsAccessAliveAcrossAwaitAndBalancesStop() async throws {
        let urlA = URL(fileURLWithPath: "/tmp/movies-connector-scope-a")
        let urlB = URL(fileURLWithPath: "/tmp/movies-connector-scope-b")

        var startCount = 0
        var stopCount = 0
        var accessDepthDuringJob = 0
        var sawPositiveDepthAcrossAwait = false

        SecurityScopedAccess.startAccessingForTesting = { _ in
            startCount += 1
            accessDepthDuringJob += 1
            return true
        }
        SecurityScopedAccess.stopAccessingForTesting = { _ in
            stopCount += 1
            accessDepthDuringJob -= 1
        }

        let value = try await SecurityScopedAccess.withAccess(to: [urlA, urlB]) {
            XCTAssertEqual(accessDepthDuringJob, 2, "Both URLs must be started before the job body runs")
            try await Task.sleep(nanoseconds: 20_000_000)
            sawPositiveDepthAcrossAwait = accessDepthDuringJob == 2
            XCTAssertEqual(accessDepthDuringJob, 2, "Access must remain held across await suspension")
            return 42
        }

        XCTAssertEqual(value, 42)
        XCTAssertTrue(sawPositiveDepthAcrossAwait)
        XCTAssertEqual(startCount, 2)
        XCTAssertEqual(stopCount, 2)
        XCTAssertEqual(accessDepthDuringJob, 0, "Every successful start must be paired with a stop")
    }

    func testAsyncOverloadDoesNotStopWhenStartReturnsFalse() async throws {
        let url = URL(fileURLWithPath: "/tmp/movies-connector-scope-false")
        var stopCount = 0

        SecurityScopedAccess.startAccessingForTesting = { _ in false }
        SecurityScopedAccess.stopAccessingForTesting = { _ in stopCount += 1 }

        _ = try await SecurityScopedAccess.withAccess(to: url) {
            try await Task.sleep(nanoseconds: 5_000_000)
            return true
        }

        XCTAssertEqual(stopCount, 0)
    }

    func testAsyncOverloadBalancesStopWhenBodyThrows() async {
        let url = URL(fileURLWithPath: "/tmp/movies-connector-scope-throw")
        var startCount = 0
        var stopCount = 0

        SecurityScopedAccess.startAccessingForTesting = { _ in
            startCount += 1
            return true
        }
        SecurityScopedAccess.stopAccessingForTesting = { _ in stopCount += 1 }

        do {
            try await SecurityScopedAccess.withAccess(to: url) {
                try await Task.sleep(nanoseconds: 5_000_000)
                throw CancellationError()
            }
            XCTFail("Expected throw")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(stopCount, 1)
    }
}
