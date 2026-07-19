import XCTest
@testable import MoviesConnector

final class UserSelectedURLAccessTests: XCTestCase {
    override func tearDown() {
        UserSelectedURLAccess.resetForTesting()
        super.tearDown()
    }

    func testPreparedAccessBalancesStartStopAcrossAwaitAndCancellation() async {
        let input = URL(fileURLWithPath: "/tmp/movies-connector-input.mov")
        let output = URL(fileURLWithPath: "/tmp/movies-connector-output.mov")

        var startCount = 0
        var stopCount = 0
        var depth = 0

        SecurityScopedAccess.startAccessingForTesting = { _ in
            startCount += 1
            depth += 1
            return true
        }
        SecurityScopedAccess.stopAccessingForTesting = { _ in
            stopCount += 1
            depth -= 1
        }
        UserSelectedURLAccess.ensureLocalCopyForTesting = { _ in }

        do {
            try await UserSelectedURLAccess.withPreparedAccess(to: [input, output]) {
                XCTAssertEqual(depth, 2)
                try await Task.sleep(nanoseconds: 10_000_000)
                throw CancellationError()
            }
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(startCount, 2)
        XCTAssertEqual(stopCount, 2)
        XCTAssertEqual(depth, 0)
    }

    func testPreparedAccessSurfacesSecurityScopedDenialAndStillStopsSuccessfulStarts() async {
        let ok = URL(fileURLWithPath: "/tmp/movies-connector-ok.mov")
        let denied = URL(fileURLWithPath: "/tmp/movies-connector-denied.mov")

        var stopped: [URL] = []
        SecurityScopedAccess.startAccessingForTesting = { url in
            url == ok
        }
        SecurityScopedAccess.stopAccessingForTesting = { url in
            stopped.append(url)
        }
        UserSelectedURLAccess.ensureLocalCopyForTesting = { _ in }

        do {
            try await UserSelectedURLAccess.withPreparedAccess(
                to: [ok, denied],
                requireSecurityScopedAccess: true
            ) {
                XCTFail("Body should not run when access is required and denied")
            }
            XCTFail("Expected securityScopedAccessDenied")
        } catch let error as UserSelectedURLAccessError {
            XCTAssertEqual(error, .securityScopedAccessDenied(denied))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(stopped, [ok])
    }

    func testPreparedAccessSurfacesICloudDownloadErrors() async {
        let url = URL(fileURLWithPath: "/tmp/movies-connector-icloud.mov")
        SecurityScopedAccess.startAccessingForTesting = { _ in true }
        SecurityScopedAccess.stopAccessingForTesting = { _ in }
        UserSelectedURLAccess.isUbiquitousItemForTesting = { _ in true }
        UserSelectedURLAccess.ensureLocalCopyForTesting = { url in
            throw UserSelectedURLAccessError.iCloudDownloadFailed(url, "offline")
        }

        do {
            try await UserSelectedURLAccess.withPreparedAccess(to: url) {
                XCTFail("Body should not run")
            }
            XCTFail("Expected iCloudDownloadFailed")
        } catch let error as UserSelectedURLAccessError {
            XCTAssertEqual(error, .iCloudDownloadFailed(url, "offline"))
            XCTAssertTrue(error.localizedDescription.contains("offline"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testPreparedAccessRunsBodyForLocalNonUbiquitousURLs() async throws {
        let url = URL(fileURLWithPath: "/tmp/movies-connector-local.mov")
        var ensureCalls = 0

        SecurityScopedAccess.startAccessingForTesting = { _ in true }
        SecurityScopedAccess.stopAccessingForTesting = { _ in }
        UserSelectedURLAccess.isUbiquitousItemForTesting = { _ in false }
        UserSelectedURLAccess.ensureLocalCopyForTesting = { _ in
            ensureCalls += 1
        }

        let value = try await UserSelectedURLAccess.withPreparedAccess(to: url) {
            7
        }

        XCTAssertEqual(value, 7)
        XCTAssertEqual(ensureCalls, 1)
    }
}
