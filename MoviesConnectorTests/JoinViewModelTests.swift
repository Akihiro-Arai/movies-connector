import XCTest
@testable import MoviesConnector

@MainActor
final class JoinViewModelTests: XCTestCase {
    func testAddPreservesOrderAndStableDistinctIdentitiesForSameURL() async {
        let url = URL(fileURLWithPath: "/tmp/same.mov")
        let inspector = MockAssetInspector(results: [
            url: .success(Self.inspection(duration: 1, width: 320)),
        ])
        let viewModel = makeViewModel(inspector: inspector)

        viewModel.addURLs([url, url])
        await waitUntil(viewModel) { $0.items.allSatisfy { $0.compatibility == .compatible } }

        XCTAssertEqual(viewModel.items.count, 2)
        XCTAssertEqual(viewModel.items[0].url, url)
        XCTAssertEqual(viewModel.items[1].url, url)
        XCTAssertNotEqual(viewModel.items[0].id, viewModel.items[1].id)
        XCTAssertEqual(viewModel.orderedInputURLs, [url, url])
    }

    func testReorderChangesCanonicalOrderAndRecomputesCompatibility() async {
        let a = URL(fileURLWithPath: "/tmp/a.mov")
        let b = URL(fileURLWithPath: "/tmp/b.mov")
        let inspector = MockAssetInspector(results: [
            a: .success(Self.inspection(duration: 1, width: 320)),
            b: .success(Self.inspection(duration: 2, width: 640)),
        ])
        let viewModel = makeViewModel(inspector: inspector)

        viewModel.addURLs([a, b])
        await waitUntil(viewModel) { self.itemsReady($0) }

        XCTAssertEqual(viewModel.items[0].compatibility, .compatible)
        if case .incompatible(let reason) = viewModel.items[1].compatibility {
            XCTAssertTrue(reason.contains("display size"), reason)
        } else {
            XCTFail("Expected second item incompatible against 320 reference")
        }

        viewModel.moveItems(from: IndexSet(integer: 1), to: 0)
        XCTAssertEqual(viewModel.orderedInputURLs, [b, a])
        XCTAssertEqual(viewModel.items[0].compatibility, .compatible)
        if case .incompatible(let reason) = viewModel.items[1].compatibility {
            XCTAssertTrue(reason.contains("display size"), reason)
        } else {
            XCTFail("Expected former reference incompatible against 640 reference")
        }
        XCTAssertEqual(inspector.inspectCallCount, 2, "Reorder should recompute from cached signatures")
    }

    func testDeleteRemovesItemAndRecomputesAgainstNewReference() async {
        let a = URL(fileURLWithPath: "/tmp/a.mov")
        let b = URL(fileURLWithPath: "/tmp/b.mov")
        let c = URL(fileURLWithPath: "/tmp/c.mov")
        let inspector = MockAssetInspector(results: [
            a: .success(Self.inspection(duration: 1, width: 320)),
            b: .success(Self.inspection(duration: 2, width: 640)),
            c: .success(Self.inspection(duration: 3, width: 640)),
        ])
        let viewModel = makeViewModel(inspector: inspector)

        viewModel.addURLs([a, b, c])
        await waitUntil(viewModel) { self.itemsReady($0) }

        let removed = viewModel.items[0].id
        viewModel.removeItem(id: removed)

        XCTAssertEqual(viewModel.orderedInputURLs, [b, c])
        XCTAssertEqual(viewModel.items.map(\.compatibility), [.compatible, .compatible])
    }

    func testCanJoinDisabledWhenEmptyInspectingIncompatibleOrMissingOutput() async {
        let a = URL(fileURLWithPath: "/tmp/a.mov")
        let b = URL(fileURLWithPath: "/tmp/b.mov")
        let gate = InspectionGate()
        let inspector = MockAssetInspector(
            results: [
                a: .success(Self.inspection(duration: 1, width: 320)),
                b: .success(Self.inspection(duration: 2, width: 640)),
            ],
            gate: gate
        )
        let viewModel = makeViewModel(inspector: inspector)

        XCTAssertFalse(viewModel.canJoin, "Empty queue")

        viewModel.addURLs([a])
        XCTAssertFalse(viewModel.canJoin, "Inspecting + no output")

        await inspector.waitUntilInspectEntered(count: 1)
        gate.resumeAll()
        await waitUntil(viewModel) { $0.items.first?.compatibility == .compatible }
        XCTAssertFalse(viewModel.canJoin, "Compatible but no output")

        viewModel.setOutputURLForTesting(URL(fileURLWithPath: "/tmp/out.mov"))
        XCTAssertTrue(viewModel.canJoin)

        viewModel.addURLs([b])
        XCTAssertFalse(viewModel.canJoin, "New item present while not fully compatible")
        await inspector.waitUntilInspectEntered(count: 2)
        gate.resumeAll()
        await waitUntil(viewModel) { self.itemsReady($0) }
        XCTAssertFalse(viewModel.canJoin, "Incompatible present")
    }

    func testStaleInspectionResultIgnoredAfterDelete() async {
        let url = URL(fileURLWithPath: "/tmp/slow.mov")
        let gate = InspectionGate()
        let inspector = MockAssetInspector(
            results: [url: .success(Self.inspection(duration: 9, width: 320))],
            gate: gate
        )
        let viewModel = makeViewModel(inspector: inspector)

        viewModel.addURLs([url])
        guard let id = viewModel.items.first?.id else {
            XCTFail("Expected queue item")
            return
        }

        // Wait until inspect has entered (and is blocked on the gate) before deleting,
        // so this is not scheduling-dependent on the unstructured Task starting.
        await inspector.waitUntilInspectEntered(count: 1)
        XCTAssertEqual(inspector.inspectCallCount, 1)

        viewModel.removeItem(id: id)
        XCTAssertTrue(viewModel.items.isEmpty)

        gate.resumeAll()
        await Task.yield()
        await Task.yield()

        XCTAssertTrue(viewModel.items.isEmpty)
        XCTAssertEqual(inspector.inspectCallCount, 1)
    }

    func testDroppedURLsUseFileAccessFilterAndSurfaceRejections() {
        let movie = URL(fileURLWithPath: "/Movies/ok.mov")
        let text = URL(fileURLWithPath: "/Movies/notes.txt")
        let mkv = URL(fileURLWithPath: "/Movies/clip.mkv")
        DroppedMovieURLFilter.resourceInfoForTesting = { url in
            if url == movie {
                return DroppedMovieURLFilter.ResourceInfo(
                    isRegularFile: true,
                    typeIdentifier: "com.apple.quicktime-movie"
                )
            }
            if url == text {
                return DroppedMovieURLFilter.ResourceInfo(
                    isRegularFile: true,
                    typeIdentifier: "public.plain-text"
                )
            }
            if url == mkv {
                // Extension fallback: mkv is outside MovieContentTypes.supportedExtensions.
                return DroppedMovieURLFilter.ResourceInfo(
                    isRegularFile: true,
                    typeIdentifier: nil
                )
            }
            return nil
        }
        defer { DroppedMovieURLFilter.resetForTesting() }

        let inspector = MockAssetInspector(results: [
            movie: .success(Self.inspection(duration: 1, width: 320)),
        ])
        let viewModel = makeViewModel(inspector: inspector)

        viewModel.addDroppedURLs([movie, text, mkv, movie])

        XCTAssertEqual(viewModel.orderedInputURLs, [movie, movie])
        XCTAssertNotNil(viewModel.statusMessage)
        XCTAssertTrue(
            viewModel.statusMessage?.contains("notes.txt") == true,
            viewModel.statusMessage ?? ""
        )
        XCTAssertTrue(
            viewModel.statusMessage?.contains("clip.mkv") == true,
            viewModel.statusMessage ?? ""
        )
    }

    func testAccessDenialSurfacesOnRowAsIncompatible() async {
        let url = URL(fileURLWithPath: "/tmp/denied.mov")
        let inspector = MockAssetInspector(results: [
            url: .failure(UserSelectedURLAccessError.securityScopedAccessDenied(url)),
        ])
        let viewModel = makeViewModel(inspector: inspector)

        viewModel.addURLs([url])
        await waitUntil(viewModel) { self.itemsReady($0) }

        guard case .incompatible(let reason) = viewModel.items.first?.compatibility else {
            XCTFail("Expected incompatible row after access denial")
            return
        }
        XCTAssertTrue(reason.contains("denied.mov") || reason.contains("Reselect"), reason)
    }

    func testJoinPassesOrderedURLsToExporter() async {
        let a = URL(fileURLWithPath: "/tmp/a.mov")
        let b = URL(fileURLWithPath: "/tmp/b.mov")
        let out = URL(fileURLWithPath: "/tmp/out.mov")
        let inspector = MockAssetInspector(results: [
            a: .success(Self.inspection(duration: 1, width: 320)),
            b: .success(Self.inspection(duration: 2, width: 320)),
        ])
        let exporter = MockExporter()
        let viewModel = makeViewModel(inspector: inspector, exporter: exporter)

        viewModel.addURLs([a, b])
        await waitUntil(viewModel) { $0.items.allSatisfy { $0.compatibility == .compatible } }
        viewModel.moveItems(from: IndexSet(integer: 1), to: 0)
        viewModel.setOutputURLForTesting(out)

        await viewModel.join()

        XCTAssertEqual(exporter.lastInputURLs, [b, a])
        XCTAssertEqual(exporter.lastOutputURL, out)
        XCTAssertEqual(viewModel.statusMessage?.contains("Joined 2"), true)
    }

    func testMutationsRejectedWhileJoiningAndSnapshotDrivesCompletion() async {
        let a = URL(fileURLWithPath: "/tmp/a.mov")
        let b = URL(fileURLWithPath: "/tmp/b.mov")
        let c = URL(fileURLWithPath: "/tmp/c.mov")
        let out = URL(fileURLWithPath: "/tmp/out.mov")
        let inspector = MockAssetInspector(results: [
            a: .success(Self.inspection(duration: 1, width: 320)),
            b: .success(Self.inspection(duration: 2, width: 320)),
            c: .success(Self.inspection(duration: 3, width: 320)),
        ])
        let gate = ExportGate()
        let exporter = GatedMockExporter(gate: gate)
        let viewModel = makeViewModel(inspector: inspector, exporter: exporter)

        viewModel.addURLs([a, b])
        await waitUntil(viewModel) { $0.items.allSatisfy { $0.compatibility == .compatible } }
        viewModel.setOutputURLForTesting(out)

        let joinTask = Task { await viewModel.join() }
        await exporter.waitUntilJoinEntered()
        XCTAssertTrue(viewModel.isJoining)
        XCTAssertGreaterThan(viewModel.joinProgress, 0)

        let itemCountBefore = viewModel.items.count
        let firstID = viewModel.items[0].id
        viewModel.addURLs([c])
        viewModel.removeItem(id: firstID)
        viewModel.moveItems(from: IndexSet(integer: 0), to: 1)
        viewModel.setOutputURLForTesting(URL(fileURLWithPath: "/tmp/other.mov"))
        viewModel.addDroppedURLs([c])

        XCTAssertEqual(viewModel.items.count, itemCountBefore)
        XCTAssertEqual(viewModel.orderedInputURLs, [a, b])
        XCTAssertEqual(viewModel.outputURL, out)

        var progressSamples: [Double] = []
        for _ in 0..<20 {
            progressSamples.append(viewModel.joinProgress)
            await Task.yield()
        }

        gate.resume()
        await joinTask.value

        XCTAssertFalse(viewModel.isJoining)
        XCTAssertEqual(viewModel.joinProgress, 1)
        XCTAssertEqual(exporter.lastInputURLs, [a, b])
        XCTAssertEqual(exporter.lastOutputURL, out)
        XCTAssertEqual(viewModel.statusMessage, "Joined 2 video(s) → out.mov")
        XCTAssertEqual(viewModel.orderedInputURLs, [a, b], "Queue must remain frozen during join")
        for index in 1..<progressSamples.count {
            XCTAssertGreaterThanOrEqual(progressSamples[index], progressSamples[index - 1])
        }
    }

    func testCancelJoinSurfacesCancelledStatus() async {
        let a = URL(fileURLWithPath: "/tmp/a.mov")
        let out = URL(fileURLWithPath: "/tmp/out.mov")
        let inspector = MockAssetInspector(results: [
            a: .success(Self.inspection(duration: 1, width: 320)),
        ])
        let gate = ExportGate()
        let exporter = GatedMockExporter(gate: gate, throwOnResume: CancellationError())
        let viewModel = makeViewModel(inspector: inspector, exporter: exporter)

        viewModel.addURLs([a])
        await waitUntil(viewModel) { $0.items.allSatisfy { $0.compatibility == .compatible } }
        viewModel.setOutputURLForTesting(out)

        viewModel.startJoin()
        await exporter.waitUntilJoinEntered()
        XCTAssertTrue(viewModel.canCancelJoin)
        viewModel.cancelJoin()
        gate.resume()

        await waitUntil(viewModel) { !$0.isJoining }
        XCTAssertEqual(viewModel.statusMessage, JoinExporterError.cancelled.errorDescription)
    }

    func testDurationFormatting() {
        XCTAssertEqual(DurationFormatting.string(from: nil), "—")
        XCTAssertEqual(DurationFormatting.string(from: 65), "1:05")
        XCTAssertEqual(DurationFormatting.string(from: 3661), "1:01:01")
    }

    // MARK: - Helpers

    private func makeViewModel(
        inspector: MockAssetInspector,
        exporter: any JoinExporting = MockExporter()
    ) -> JoinViewModel {
        JoinViewModel(
            inspector: inspector,
            videoSelector: MockVideoSelector(urls: []),
            outputSelector: MockOutputSelector(url: nil),
            exporter: exporter
        )
    }

    private func itemsReady(_ viewModel: JoinViewModel) -> Bool {
        viewModel.items.allSatisfy {
            if case .inspecting = $0.compatibility { return false }
            return true
        }
    }

    private func waitUntil(
        _ viewModel: JoinViewModel,
        timeout: TimeInterval = 2,
        condition: @escaping (JoinViewModel) -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition(viewModel) { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Condition not met before timeout")
    }

    private static func inspection(duration: TimeInterval, width: Int) -> JoinInspectionResult {
        JoinInspectionResult(
            duration: duration,
            signature: CompatibilitySignature(
                videoTrackCount: 1,
                audioTrackCount: 0,
                hasUnsupportedTracks: false,
                videoCodec: "avc1",
                videoDisplayWidth: width,
                videoDisplayHeight: 240,
                videoPreferredTransform: .identity,
                videoFrameDuration: .init(value: 1, timescale: 30),
                videoTimescale: 30,
                audioCodec: nil,
                audioSampleRate: nil,
                audioChannelCount: nil,
                audioFormatFlags: nil
            )
        )
    }
}

// MARK: - Test doubles

private final class InspectionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func waitIfNeeded() async {
        lock.lock()
        if isOpen {
            lock.unlock()
            return
        }
        lock.unlock()

        await withCheckedContinuation { continuation in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                continuations.append(continuation)
                lock.unlock()
            }
        }
    }

    func resumeAll() {
        lock.lock()
        isOpen = true
        let pending = continuations
        continuations.removeAll()
        lock.unlock()
        for continuation in pending {
            continuation.resume()
        }
    }
}

private final class MockAssetInspector: AssetInspecting, @unchecked Sendable {
    private let results: [URL: Result<JoinInspectionResult, Error>]
    private let gate: InspectionGate?
    private let lock = NSLock()
    private(set) var inspectCallCount = 0
    private var entryWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(results: [URL: Result<JoinInspectionResult, Error>], gate: InspectionGate? = nil) {
        self.results = results
        self.gate = gate
    }

    func waitUntilInspectEntered(count: Int = 1) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if inspectCallCount >= count {
                lock.unlock()
                continuation.resume()
            } else {
                entryWaiters.append((count, continuation))
                lock.unlock()
            }
        }
    }

    func inspect(url: URL) async throws -> JoinInspectionResult {
        lock.lock()
        inspectCallCount += 1
        let currentCount = inspectCallCount
        let ready = entryWaiters.filter { currentCount >= $0.count }
        entryWaiters.removeAll { currentCount >= $0.count }
        lock.unlock()
        for waiter in ready {
            waiter.continuation.resume()
        }

        if let gate {
            await gate.waitIfNeeded()
        }
        switch results[url] {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        case nil:
            throw NSError(domain: "MockAssetInspector", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Unexpected URL \(url.path)",
            ])
        }
    }
}

private final class MockVideoSelector: VideoFileSelecting {
    var urls: [URL]
    init(urls: [URL]) { self.urls = urls }
    func selectVideos() async -> [URL] { urls }
}

private final class MockOutputSelector: OutputDestinationSelecting {
    var url: URL?
    init(url: URL?) { self.url = url }
    func selectOutputDestination(suggestedName: String) async -> URL? { url }
}

private final class MockExporter: JoinExporting, @unchecked Sendable {
    private(set) var lastInputURLs: [URL]?
    private(set) var lastOutputURL: URL?

    func join(
        inputURLs: [URL],
        outputURL: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        lastInputURLs = inputURLs
        lastOutputURL = outputURL
        progress?(1)
    }
}

private final class ExportGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func waitIfNeeded() async {
        lock.lock()
        if isOpen {
            lock.unlock()
            return
        }
        lock.unlock()

        await withCheckedContinuation { continuation in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                continuations.append(continuation)
                lock.unlock()
            }
        }
    }

    func resume() {
        lock.lock()
        isOpen = true
        let pending = continuations
        continuations.removeAll()
        lock.unlock()
        for continuation in pending {
            continuation.resume()
        }
    }
}

private final class GatedMockExporter: JoinExporting, @unchecked Sendable {
    private let gate: ExportGate
    private let throwOnResume: Error?
    private let lock = NSLock()
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var joinEntered = false
    private(set) var lastInputURLs: [URL]?
    private(set) var lastOutputURL: URL?

    init(gate: ExportGate, throwOnResume: Error? = nil) {
        self.gate = gate
        self.throwOnResume = throwOnResume
    }

    func waitUntilJoinEntered() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if joinEntered {
                lock.unlock()
                continuation.resume()
            } else {
                entryWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func join(
        inputURLs: [URL],
        outputURL: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        lastInputURLs = inputURLs
        lastOutputURL = outputURL
        progress?(0.2)

        lock.lock()
        joinEntered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        lock.unlock()
        for waiter in waiters {
            waiter.resume()
        }

        await gate.waitIfNeeded()
        try Task.checkCancellation()
        if let throwOnResume {
            throw throwOnResume
        }
        progress?(1)
    }
}
