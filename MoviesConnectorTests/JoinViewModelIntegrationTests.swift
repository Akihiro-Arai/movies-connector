import AVFoundation
import XCTest
@testable import MoviesConnector

/// Integration coverage for issue #6: default production `JoinViewModel` adapters
/// (FileAccess panels/security-scope seams → `DefaultAssetInspector`/`AssetInspector`
/// → `DefaultJoinExporter`/`JoinExporter`) with real movie fixtures.
@MainActor
final class JoinViewModelIntegrationTests: XCTestCase {
    private var outputDirectory: URL!
    private let accessLog = AccessLog()

    override func setUp() async throws {
        try await super.setUp()
        JoinExporter.resetForTesting()
        AssetInspector.resetForTesting()
        UserSelectedURLAccess.resetForTesting()
        SecurityScopedAccess.resetAccessorsForTesting()
        MovieOpenPanel.resetForTesting()
        MovieSavePanel.resetForTesting()
        DroppedMovieURLFilter.resetForTesting()

        outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("movies-connector-join-vm-integration", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        accessLog.reset()
        installPermissiveAccessMocks()
    }

    override func tearDown() {
        JoinExporter.resetForTesting()
        AssetInspector.resetForTesting()
        UserSelectedURLAccess.resetForTesting()
        SecurityScopedAccess.resetAccessorsForTesting()
        MovieOpenPanel.resetForTesting()
        MovieSavePanel.resetForTesting()
        DroppedMovieURLFilter.resetForTesting()
        if let outputDirectory {
            try? FileManager.default.removeItem(at: outputDirectory)
        }
        super.tearDown()
    }

    func testProductionHappyPathSelectInspectReorderAndExport() async throws {
        let a = try await TestMovieFixtures.url(named: "compat_a.mov")
        let b = try await TestMovieFixtures.url(named: "compat_b.mov")
        let output = outputDirectory.appendingPathComponent("happy-joined.mov")

        // Panel seams only — production selector adapters + inspector + exporter stay default.
        MovieOpenPanel.presentForTesting = { [b, a] }
        MovieSavePanel.presentForTesting = { suggested in
            XCTAssertTrue(suggested.hasSuffix("-joined.mov"), suggested)
            return output
        }

        let viewModel = JoinViewModel()

        await viewModel.addVideos()
        XCTAssertEqual(viewModel.orderedInputURLs, [b, a])
        await waitUntil(viewModel, timeout: 30) { self.itemsFullyInspected($0) }
        XCTAssertEqual(
            viewModel.items.map(\.compatibility),
            [.compatible, .compatible]
        )

        // Reorder to visible queue order [a, b] before export.
        viewModel.moveItems(from: IndexSet(integer: 1), to: 0)
        XCTAssertEqual(viewModel.orderedInputURLs, [a, b])

        await viewModel.chooseOutputDestination()
        XCTAssertEqual(viewModel.outputURL, output)
        XCTAssertTrue(viewModel.canJoin)

        await viewModel.join()

        XCTAssertFalse(viewModel.isJoining)
        XCTAssertEqual(viewModel.statusMessage, "Joined 2 video(s) → happy-joined.mov")
        XCTAssertTrue(viewModel.canJoin, "Success must leave a retryable Join state")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(viewModel.orderedInputURLs, [a, b])

        // FileAccess prepared-access path must have touched inputs and output.
        let accessed = accessLog.urls
        XCTAssertTrue(accessed.contains(a))
        XCTAssertTrue(accessed.contains(b))
        XCTAssertTrue(accessed.contains(output))

        let durationA = try await AVURLAsset(url: a).load(.duration)
        let durationB = try await AVURLAsset(url: b).load(.duration)
        let expected = CMTimeAdd(durationA, durationB)
        let outputDuration = try await AVURLAsset(url: output).load(.duration)
        XCTAssertLessThan(
            abs(outputDuration.seconds - expected.seconds),
            0.1,
            "Production exporter should produce a concatenated .mov"
        )
    }

    func testProductionIncompatiblePairDisablesJoinWithPerRowReason() async throws {
        let a = try await TestMovieFixtures.url(named: "compat_a.mov")
        let bad = try await TestMovieFixtures.url(named: "incompat_size.mov")
        let output = outputDirectory.appendingPathComponent("incompat-out.mov")

        MovieOpenPanel.presentForTesting = { [a, bad] }
        MovieSavePanel.presentForTesting = { _ in output }

        let viewModel = JoinViewModel()
        await viewModel.addVideos()
        await waitUntil(viewModel, timeout: 30) { self.itemsFullyInspected($0) }
        await viewModel.chooseOutputDestination()

        XCTAssertEqual(viewModel.items[0].compatibility, .compatible)
        guard case .incompatible(let mismatches) = viewModel.items[1].compatibility else {
            XCTFail("Expected incompatible second row from production AssetInspector signatures")
            return
        }
        let reason = mismatches.map(\.description).joined(separator: "; ")
        XCTAssertTrue(
            reason.localizedCaseInsensitiveContains("display size")
                || reason.localizedCaseInsensitiveContains("size"),
            reason
        )
        XCTAssertFalse(viewModel.canJoin)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testProductionExportFailureThenRetrySucceeds() async throws {
        let a = try await TestMovieFixtures.url(named: "compat_a.mov")
        let b = try await TestMovieFixtures.url(named: "compat_b.mov")
        let output = outputDirectory.appendingPathComponent("fail-then-retry.mov")

        MovieOpenPanel.presentForTesting = { [a, b] }
        MovieSavePanel.presentForTesting = { _ in output }

        let viewModel = JoinViewModel()
        await viewModel.addVideos()
        await waitUntil(viewModel, timeout: 30) { self.itemsFullyInspected($0) }
        await viewModel.chooseOutputDestination()
        XCTAssertTrue(viewModel.canJoin)

        // Failure injected on the production JoinExporter install seam (not a MockExporter).
        JoinExporter.installExportForTesting = { _, _ in
            throw JoinExporterError.diskFull
        }

        await viewModel.join()

        XCTAssertFalse(viewModel.isJoining)
        XCTAssertEqual(viewModel.statusMessage, JoinExporterError.diskFull.errorDescription)
        XCTAssertTrue(viewModel.canJoin)
        XCTAssertEqual(viewModel.orderedInputURLs, [a, b])
        XCTAssertEqual(viewModel.outputURL, output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))

        JoinExporter.installExportForTesting = nil

        await viewModel.join()

        XCTAssertEqual(viewModel.statusMessage, "Joined 2 video(s) → fail-then-retry.mov")
        XCTAssertTrue(viewModel.canJoin)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }

    func testProductionCancelThenRetrySucceeds() async throws {
        let a = try await TestMovieFixtures.url(named: "compat_a.mov")
        let b = try await TestMovieFixtures.url(named: "compat_b.mov")
        let output = outputDirectory.appendingPathComponent("cancel-then-retry.mov")
        let marker = "preexisting-destination"
        try marker.write(to: output, atomically: true, encoding: .utf8)

        MovieOpenPanel.presentForTesting = { [a, b] }
        MovieSavePanel.presentForTesting = { _ in output }

        let viewModel = JoinViewModel()
        await viewModel.addVideos()
        await waitUntil(viewModel, timeout: 30) { self.itemsFullyInspected($0) }
        await viewModel.chooseOutputDestination()
        XCTAssertTrue(viewModel.canJoin)

        // Async gate at the production commit boundary: prove cancelJoin() cancels the
        // in-flight exporter task. The hook must not throw CancellationError itself.
        let gate = CommitCancelGate()
        JoinExporter.exportBodyForTesting = { tempURL in
            try FileManager.default.copyItem(at: a, to: tempURL)
        }
        JoinExporter.beforeCommitForTesting = {
            await gate.markArrivedAndWaitForRelease()
            XCTAssertTrue(
                Task.isCancelled,
                "cancelJoin() must cancel the production exporter task before commit resumes"
            )
            // Return normally — JoinExporter's Task.checkCancellation() must fail next.
        }

        viewModel.startJoin()
        await gate.waitUntilArrived(timeout: 30)
        XCTAssertTrue(viewModel.isJoining, "Join must be in-flight on the production exporter path")
        XCTAssertTrue(viewModel.canCancelJoin)

        viewModel.cancelJoin()
        gate.release()

        await waitUntil(viewModel, timeout: 30) { !$0.isJoining }

        XCTAssertEqual(viewModel.statusMessage, JoinExporterError.cancelled.errorDescription)
        XCTAssertTrue(viewModel.canJoin, "Cancel must restore a retryable Join state")
        XCTAssertEqual(viewModel.orderedInputURLs, [a, b])
        XCTAssertEqual(viewModel.outputURL, output)
        XCTAssertEqual(
            try String(contentsOf: output, encoding: .utf8),
            marker,
            "Cancel must not replace a pre-existing destination (#5 safety)"
        )

        JoinExporter.exportBodyForTesting = nil
        JoinExporter.beforeCommitForTesting = nil

        await viewModel.join()

        XCTAssertEqual(viewModel.statusMessage, "Joined 2 video(s) → cancel-then-retry.mov")
        XCTAssertTrue(viewModel.canJoin)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let remaining = try? String(contentsOf: output, encoding: .utf8)
        XCTAssertNotEqual(remaining, marker, "Successful retry must install a real movie")
    }

    // MARK: - Helpers

    private func installPermissiveAccessMocks() {
        let log = accessLog
        SecurityScopedAccess.startAccessingForTesting = { url in
            log.append(url)
            return true
        }
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
    }

    private func itemsFullyInspected(_ viewModel: JoinViewModel) -> Bool {
        !viewModel.items.isEmpty && viewModel.items.allSatisfy {
            if case .inspecting = $0.compatibility { return false }
            return true
        }
    }

    private func waitUntil(
        _ viewModel: JoinViewModel,
        timeout: TimeInterval = 30,
        condition: @escaping (JoinViewModel) -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition(viewModel) { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Condition not met before timeout (\(timeout)s)")
    }

    private final class AccessLog: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [URL] = []

        var urls: [URL] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        func append(_ url: URL) {
            lock.lock()
            stored.append(url)
            lock.unlock()
        }

        func reset() {
            lock.lock()
            stored.removeAll()
            lock.unlock()
        }
    }

    /// Gate used by cancel→retry: exporter signals commit-boundary arrival, test calls
    /// `cancelJoin()`, then releases so production `Task.checkCancellation()` can fail.
    private final class CommitCancelGate: @unchecked Sendable {
        private let lock = NSLock()
        private var arrived = false
        private var released = false
        private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func markArrivedAndWaitForRelease() async {
            lock.lock()
            arrived = true
            let pendingArrival = arrivalWaiters
            arrivalWaiters.removeAll()
            let alreadyReleased = released
            lock.unlock()
            for waiter in pendingArrival {
                waiter.resume()
            }
            if alreadyReleased { return }

            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if released {
                    lock.unlock()
                    continuation.resume()
                } else {
                    releaseWaiters.append(continuation)
                    lock.unlock()
                }
            }
        }

        func waitUntilArrived(timeout: TimeInterval) async {
            lock.lock()
            if arrived {
                lock.unlock()
                return
            }
            lock.unlock()

            await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        self.lock.lock()
                        if self.arrived {
                            self.lock.unlock()
                            continuation.resume()
                        } else {
                            self.arrivalWaiters.append(continuation)
                            self.lock.unlock()
                        }
                    }
                    return true
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    return false
                }
                let first = await group.next() ?? false
                group.cancelAll()
                if !first {
                    XCTFail("Exporter did not reach commit boundary before timeout (\(timeout)s)")
                }
            }
        }

        func release() {
            lock.lock()
            released = true
            let pending = releaseWaiters
            releaseWaiters.removeAll()
            lock.unlock()
            for waiter in pending {
                waiter.resume()
            }
        }
    }
}
