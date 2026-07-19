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
        UserSelectedURLAccess.ubiquitousItemStateForTesting = { _ in
            UbiquitousItemState(
                isUbiquitous: false,
                downloadingStatus: nil,
                isDownloading: false,
                downloadingErrorDescription: nil,
                isReadable: true
            )
        }

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

    func testDefaultPreparedAccessThrowsSecurityScopedDenialAndStillStopsSuccessfulStarts() async {
        let ok = URL(fileURLWithPath: "/tmp/movies-connector-ok.mov")
        let denied = URL(fileURLWithPath: "/tmp/movies-connector-denied.mov")

        var stopped: [URL] = []
        SecurityScopedAccess.startAccessingForTesting = { url in
            url == ok
        }
        SecurityScopedAccess.stopAccessingForTesting = { url in
            stopped.append(url)
        }
        UserSelectedURLAccess.ubiquitousItemStateForTesting = { _ in
            UbiquitousItemState(
                isUbiquitous: false,
                downloadingStatus: nil,
                isDownloading: false,
                downloadingErrorDescription: nil,
                isReadable: true
            )
        }

        // Default path must require security-scoped access (no explicit true).
        do {
            try await UserSelectedURLAccess.withPreparedAccess(to: [ok, denied]) {
                XCTFail("Body should not run when access is denied by default")
            }
            XCTFail("Expected securityScopedAccessDenied")
        } catch let error as UserSelectedURLAccessError {
            XCTAssertEqual(error, .securityScopedAccessDenied(denied))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(stopped, [ok])
    }

    func testPreparedAccessOptOutAllowsMissingSecurityScopedAccess() async throws {
        let url = URL(fileURLWithPath: "/tmp/movies-connector-opt-out.mov")
        SecurityScopedAccess.startAccessingForTesting = { _ in false }
        SecurityScopedAccess.stopAccessingForTesting = { _ in }
        UserSelectedURLAccess.ubiquitousItemStateForTesting = { _ in
            UbiquitousItemState(
                isUbiquitous: false,
                downloadingStatus: nil,
                isDownloading: false,
                downloadingErrorDescription: nil,
                isReadable: true
            )
        }

        let value = try await UserSelectedURLAccess.withPreparedAccess(
            to: url,
            requireSecurityScopedAccess: false
        ) {
            11
        }

        XCTAssertEqual(value, 11)
    }

    func testPreparedAccessRunsBodyForLocalNonUbiquitousURLsWithoutStartingDownload() async throws {
        let url = URL(fileURLWithPath: "/tmp/movies-connector-local.mov")
        var downloadStarts = 0

        SecurityScopedAccess.startAccessingForTesting = { _ in true }
        SecurityScopedAccess.stopAccessingForTesting = { _ in }
        UserSelectedURLAccess.ubiquitousItemStateForTesting = { _ in
            UbiquitousItemState(
                isUbiquitous: false,
                downloadingStatus: nil,
                isDownloading: false,
                downloadingErrorDescription: nil,
                isReadable: true
            )
        }
        UserSelectedURLAccess.startDownloadingForTesting = { _ in
            downloadStarts += 1
        }

        let value = try await UserSelectedURLAccess.withPreparedAccess(to: url) {
            7
        }

        XCTAssertEqual(value, 7)
        XCTAssertEqual(downloadStarts, 0)
    }

    func testICloudAlreadyCurrentSkipsDownloadStart() async throws {
        let url = URL(fileURLWithPath: "/tmp/movies-connector-icloud-current.mov")
        var downloadStarts = 0

        SecurityScopedAccess.startAccessingForTesting = { _ in true }
        SecurityScopedAccess.stopAccessingForTesting = { _ in }
        UserSelectedURLAccess.ubiquitousItemStateForTesting = { _ in
            UbiquitousItemState(
                isUbiquitous: true,
                downloadingStatus: .current,
                isDownloading: false,
                downloadingErrorDescription: nil,
                isReadable: true
            )
        }
        UserSelectedURLAccess.startDownloadingForTesting = { _ in
            downloadStarts += 1
        }

        let value = try await UserSelectedURLAccess.withPreparedAccess(to: url) {
            3
        }

        XCTAssertEqual(value, 3)
        XCTAssertEqual(downloadStarts, 0)
    }

    func testICloudStartDownloadingFailureSurfacesDownloadFailed() async {
        let url = URL(fileURLWithPath: "/tmp/movies-connector-icloud-start-fail.mov")

        SecurityScopedAccess.startAccessingForTesting = { _ in true }
        SecurityScopedAccess.stopAccessingForTesting = { _ in }
        UserSelectedURLAccess.ubiquitousItemStateForTesting = { _ in
            UbiquitousItemState(
                isUbiquitous: true,
                downloadingStatus: .notDownloaded,
                isDownloading: false,
                downloadingErrorDescription: nil,
                isReadable: false
            )
        }
        UserSelectedURLAccess.startDownloadingForTesting = { _ in
            throw NSError(domain: "test", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "start failed",
            ])
        }

        do {
            try await UserSelectedURLAccess.withPreparedAccess(to: url) {
                XCTFail("Body should not run")
            }
            XCTFail("Expected iCloudDownloadFailed")
        } catch let error as UserSelectedURLAccessError {
            XCTAssertEqual(error, .iCloudDownloadFailed(url, "start failed"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testICloudDownloadErrorDuringPollSurfacesDownloadFailed() async {
        let url = URL(fileURLWithPath: "/tmp/movies-connector-icloud-error.mov")
        var polls = 0

        SecurityScopedAccess.startAccessingForTesting = { _ in true }
        SecurityScopedAccess.stopAccessingForTesting = { _ in }
        UserSelectedURLAccess.startDownloadingForTesting = { _ in }
        UserSelectedURLAccess.sleepForTesting = { _ in }
        UserSelectedURLAccess.ubiquitousItemStateForTesting = { _ in
            polls += 1
            if polls == 1 {
                return UbiquitousItemState(
                    isUbiquitous: true,
                    downloadingStatus: .notDownloaded,
                    isDownloading: false,
                    downloadingErrorDescription: nil,
                    isReadable: false
                )
            }
            return UbiquitousItemState(
                isUbiquitous: true,
                downloadingStatus: .notDownloaded,
                isDownloading: true,
                downloadingErrorDescription: "offline",
                isReadable: false
            )
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

    func testICloudLongDownloadProgressThenCurrentSucceeds() async throws {
        let url = URL(fileURLWithPath: "/tmp/movies-connector-icloud-progress.mov")
        var polls = 0
        var sleepCount = 0
        var downloadStarts = 0

        SecurityScopedAccess.startAccessingForTesting = { _ in true }
        SecurityScopedAccess.stopAccessingForTesting = { _ in }
        UserSelectedURLAccess.startDownloadingForTesting = { _ in
            downloadStarts += 1
        }
        UserSelectedURLAccess.sleepForTesting = { _ in
            sleepCount += 1
        }
        UserSelectedURLAccess.ubiquitousItemStateForTesting = { _ in
            polls += 1
            // Initial check + several in-progress polls, then current.
            if polls <= 4 {
                return UbiquitousItemState(
                    isUbiquitous: true,
                    downloadingStatus: .notDownloaded,
                    isDownloading: true,
                    downloadingErrorDescription: nil,
                    isReadable: false
                )
            }
            return UbiquitousItemState(
                isUbiquitous: true,
                downloadingStatus: .current,
                isDownloading: false,
                downloadingErrorDescription: nil,
                isReadable: true
            )
        }

        let value = try await UserSelectedURLAccess.withPreparedAccess(to: url) {
            9
        }

        XCTAssertEqual(value, 9)
        XCTAssertEqual(downloadStarts, 1)
        XCTAssertGreaterThanOrEqual(sleepCount, 3)
        XCTAssertGreaterThanOrEqual(polls, 5)
    }

    func testICloudInProgressDownloadIsNotUnavailableWithoutCallerTimeout() async throws {
        let url = URL(fileURLWithPath: "/tmp/movies-connector-icloud-no-timeout.mov")
        var polls = 0

        SecurityScopedAccess.startAccessingForTesting = { _ in true }
        SecurityScopedAccess.stopAccessingForTesting = { _ in }
        UserSelectedURLAccess.startDownloadingForTesting = { _ in }
        UserSelectedURLAccess.sleepForTesting = { _ in }
        UserSelectedURLAccess.ubiquitousItemStateForTesting = { _ in
            polls += 1
            if polls < 6 {
                return UbiquitousItemState(
                    isUbiquitous: true,
                    downloadingStatus: .notDownloaded,
                    isDownloading: true,
                    downloadingErrorDescription: nil,
                    isReadable: false
                )
            }
            return UbiquitousItemState(
                isUbiquitous: true,
                downloadingStatus: .current,
                isDownloading: false,
                downloadingErrorDescription: nil,
                isReadable: true
            )
        }

        // No fixed 30s timeout: progress continues until current.
        _ = try await UserSelectedURLAccess.withPreparedAccess(to: url) {
            true
        }
        XCTAssertGreaterThanOrEqual(polls, 6)
    }

    func testICloudCallerTimeoutWhileDownloadingThrowsTimedOutNotUnavailable() async {
        let url = URL(fileURLWithPath: "/tmp/movies-connector-icloud-timeout.mov")
        var now = Date(timeIntervalSince1970: 1_000)

        SecurityScopedAccess.startAccessingForTesting = { _ in true }
        SecurityScopedAccess.stopAccessingForTesting = { _ in }
        UserSelectedURLAccess.startDownloadingForTesting = { _ in }
        UserSelectedURLAccess.nowForTesting = { now }
        UserSelectedURLAccess.sleepForTesting = { _ in
            now = now.addingTimeInterval(1)
        }
        UserSelectedURLAccess.ubiquitousItemStateForTesting = { _ in
            UbiquitousItemState(
                isUbiquitous: true,
                downloadingStatus: .notDownloaded,
                isDownloading: true,
                downloadingErrorDescription: nil,
                isReadable: false
            )
        }

        do {
            try await UserSelectedURLAccess.withPreparedAccess(
                to: url,
                iCloudDownloadTimeout: 0.5
            ) {
                XCTFail("Body should not run")
            }
            XCTFail("Expected iCloudDownloadTimedOut")
        } catch let error as UserSelectedURLAccessError {
            XCTAssertEqual(error, .iCloudDownloadTimedOut(url))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testICloudNotDownloadingAndUnreadableIsUnavailable() async {
        let url = URL(fileURLWithPath: "/tmp/movies-connector-icloud-unavailable.mov")

        SecurityScopedAccess.startAccessingForTesting = { _ in true }
        SecurityScopedAccess.stopAccessingForTesting = { _ in }
        UserSelectedURLAccess.startDownloadingForTesting = { _ in }
        UserSelectedURLAccess.ubiquitousItemStateForTesting = { _ in
            UbiquitousItemState(
                isUbiquitous: true,
                downloadingStatus: .notDownloaded,
                isDownloading: false,
                downloadingErrorDescription: nil,
                isReadable: false
            )
        }

        do {
            try await UserSelectedURLAccess.withPreparedAccess(to: url) {
                XCTFail("Body should not run")
            }
            XCTFail("Expected iCloudItemUnavailable")
        } catch let error as UserSelectedURLAccessError {
            XCTAssertEqual(error, .iCloudItemUnavailable(url))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testICloudCancellationDuringDownloadProgress() async {
        let url = URL(fileURLWithPath: "/tmp/movies-connector-icloud-cancel.mov")

        SecurityScopedAccess.startAccessingForTesting = { _ in true }
        SecurityScopedAccess.stopAccessingForTesting = { _ in }
        UserSelectedURLAccess.startDownloadingForTesting = { _ in }
        UserSelectedURLAccess.ubiquitousItemStateForTesting = { _ in
            UbiquitousItemState(
                isUbiquitous: true,
                downloadingStatus: .notDownloaded,
                isDownloading: true,
                downloadingErrorDescription: nil,
                isReadable: false
            )
        }
        UserSelectedURLAccess.sleepForTesting = { _ in
            throw CancellationError()
        }

        do {
            try await UserSelectedURLAccess.withPreparedAccess(to: url) {
                XCTFail("Body should not run")
            }
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
