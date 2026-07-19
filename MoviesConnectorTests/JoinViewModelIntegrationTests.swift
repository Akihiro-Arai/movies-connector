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
        guard case .incompatible(let reason) = viewModel.items[1].compatibility else {
            XCTFail("Expected incompatible second row from production AssetInspector signatures")
            return
        }
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

        final class CancelBox: @unchecked Sendable {
            var cancel: (@Sendable () -> Void)?
        }
        let box = CancelBox()
        box.cancel = {
            Task { @MainActor in
                viewModel.cancelJoin()
            }
        }

        // Exercise cancel on the production exporter commit boundary, then retry for real.
        JoinExporter.exportBodyForTesting = { tempURL in
            try FileManager.default.copyItem(at: a, to: tempURL)
        }
        JoinExporter.beforeCommitForTesting = {
            box.cancel?()
            throw CancellationError()
        }

        viewModel.startJoin()
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
}
