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

        gate.resumeAll()
        await waitUntil(viewModel) { $0.items.first?.compatibility == .compatible }
        XCTAssertFalse(viewModel.canJoin, "Compatible but no output")

        viewModel.setOutputURLForTesting(URL(fileURLWithPath: "/tmp/out.mov"))
        XCTAssertTrue(viewModel.canJoin)

        viewModel.addURLs([b])
        XCTAssertFalse(viewModel.canJoin, "New item present while not fully compatible")
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
        viewModel.removeItem(id: id)
        XCTAssertTrue(viewModel.items.isEmpty)

        gate.resumeAll()
        await Task.yield()
        await Task.yield()

        XCTAssertTrue(viewModel.items.isEmpty)
        XCTAssertEqual(inspector.inspectCallCount, 1)
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

    func testDurationFormatting() {
        XCTAssertEqual(DurationFormatting.string(from: nil), "—")
        XCTAssertEqual(DurationFormatting.string(from: 65), "1:05")
        XCTAssertEqual(DurationFormatting.string(from: 3661), "1:01:01")
    }

    // MARK: - Helpers

    private func makeViewModel(
        inspector: MockAssetInspector,
        exporter: MockExporter = MockExporter()
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

    init(results: [URL: Result<JoinInspectionResult, Error>], gate: InspectionGate? = nil) {
        self.results = results
        self.gate = gate
    }

    func inspect(url: URL) async throws -> JoinInspectionResult {
        lock.lock()
        inspectCallCount += 1
        lock.unlock()
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

    func join(inputURLs: [URL], outputURL: URL) async throws {
        lastInputURLs = inputURLs
        lastOutputURL = outputURL
    }
}
