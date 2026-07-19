import AVFoundation
import XCTest
@testable import MoviesConnector

final class AssetInspectorTests: XCTestCase {
    func testVideoTimescaleUsesNaturalTimeScaleNotTimeRangeStart() async throws {
        let fixtureURL = try Self.ensureCompatFixture()
        let asset = AVURLAsset(url: fixtureURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let videoTrack = try XCTUnwrap(videoTracks.first)

        let timeRange = try await videoTrack.load(.timeRange)
        let naturalTimeScale = try await videoTrack.load(.naturalTimeScale)

        // Generated fixtures use a zero start (0/1); naturalTimeScale is the real media timescale.
        XCTAssertEqual(timeRange.start.timescale, 1, "Fixture precondition: start timescale is 1")
        XCTAssertNotEqual(
            naturalTimeScale,
            timeRange.start.timescale,
            "Fixture precondition: naturalTimeScale must differ from timeRange.start.timescale"
        )
        XCTAssertGreaterThan(naturalTimeScale, 1)

        let signature = try await AssetInspector.makeSignature(for: fixtureURL)
        XCTAssertEqual(
            signature.videoTimescale,
            naturalTimeScale,
            "videoTimescale must come from AVAssetTrack.naturalTimeScale, not timeRange.start.timescale"
        )
        XCTAssertNotEqual(
            signature.videoTimescale,
            timeRange.start.timescale,
            "Regression: storing timeRange.start.timescale would incorrectly yield \(timeRange.start.timescale)"
        )
    }

    func testInspectReturnsDurationAndSignatureForCompatibleFixture() async throws {
        let url = try Self.ensureCompatFixture()
        let result = await AssetInspector.inspect(url)

        XCTAssertEqual(result.url, url)
        XCTAssertEqual(result.index, 0)
        XCTAssertNotNil(result.duration)
        XCTAssertGreaterThan(result.duration?.seconds ?? 0, 0)
        XCTAssertNotNil(result.signature)
        XCTAssertEqual(result.signature?.videoTrackCount, 1)
        XCTAssertEqual(result.signature?.videoCodec, "avc1")
        XCTAssertEqual(result.status, .compatible)
    }

    func testCompatiblePairPassesPreflight() async throws {
        let a = try Self.fixtureURL("compat_a.mov")
        let b = try Self.fixtureURL("compat_b.mov")
        let report = await AssetInspector.preflight(urls: [a, b])

        XCTAssertTrue(report.canExport)
        XCTAssertEqual(report.results.count, 2)
        XCTAssertEqual(report.results.map(\.url), [a, b])
        XCTAssertEqual(report.results.map(\.index), [0, 1])
        XCTAssertTrue(report.results.allSatisfy { $0.status == .compatible })
        XCTAssertTrue(report.rowReasons.isEmpty)
    }

    func testDisplaySizeMismatchProducesRowAddressableReason() async throws {
        let a = try Self.fixtureURL("compat_a.mov")
        let bad = try Self.fixtureURL("incompat_size.mov")
        let report = await AssetInspector.preflight(urls: [a, bad])

        XCTAssertFalse(report.canExport)
        XCTAssertEqual(report.results[0].status, .compatible)
        guard case .mismatch(let mismatches) = report.results[1].status else {
            return XCTFail("Expected mismatch on file[1], got \(report.results[1].status)")
        }
        XCTAssertTrue(
            mismatches.contains(
                .videoDisplaySize("320x240", "640x360")
            )
        )
        XCTAssertEqual(report.rowReasons.map(\.index), [1])
        XCTAssertTrue(
            report.formattedReasons.contains {
                $0.contains("file[1]:") && $0.contains("display size")
            }
        )
    }

    func testFrameDurationMismatchProducesRowAddressableReason() async throws {
        let a = try Self.fixtureURL("compat_a.mov")
        let bad = try Self.fixtureURL("incompat_fps.mov")
        let report = await AssetInspector.preflight(urls: [a, bad])

        XCTAssertFalse(report.canExport)
        guard case .mismatch(let mismatches) = report.results[1].status else {
            return XCTFail("Expected mismatch on file[1], got \(report.results[1].status)")
        }
        XCTAssertTrue(
            mismatches.contains(where: {
                if case .videoFrameDuration = $0 { return true }
                return false
            })
        )
    }

    func testUnreadableInputIsReportedWithoutCrashing() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("movies-connector-missing-\(UUID().uuidString).mov")
        let readable = try Self.ensureCompatFixture()

        let report = await AssetInspector.preflight(urls: [missing, readable])
        XCTAssertFalse(report.canExport)
        guard case .unreadable = report.results[0].status else {
            return XCTFail("Expected unreadable reference, got \(report.results[0].status)")
        }
        XCTAssertNil(report.results[0].signature)
        guard case .unsupported(let detail) = report.results[1].status else {
            return XCTFail("Expected unsupported candidate when reference is unreadable")
        }
        XCTAssertTrue(detail.contains("reference asset is unreadable"))
    }

    func testBatchPreflightPreservesCallerOrder() async throws {
        let a = try Self.fixtureURL("compat_a.mov")
        let b = try Self.fixtureURL("compat_b.mov")
        let size = try Self.fixtureURL("incompat_size.mov")
        let urls = [size, b, a]

        let report = await AssetInspector.preflight(urls: urls)
        XCTAssertEqual(report.results.map(\.url), urls)
        XCTAssertEqual(report.results.map(\.index), [0, 1, 2])
    }

    func testReferenceChangeRecomputesCompatibility() async throws {
        let a = try Self.fixtureURL("compat_a.mov")
        let size = try Self.fixtureURL("incompat_size.mov")

        let forward = await AssetInspector.preflight(urls: [a, size])
        XCTAssertEqual(forward.results[0].status, .compatible)
        XCTAssertFalse(forward.results[1].status.isAcceptable)

        let reversed = AssetInspector.preflight(reusing: forward.results.reversed())
        XCTAssertEqual(reversed.results.map(\.url), [size, a])
        XCTAssertEqual(reversed.results.map(\.index), [0, 1])
        // New reference (size) is intrinsically valid topology; candidate (a) mismatches size.
        XCTAssertEqual(reversed.results[0].status, .compatible)
        guard case .mismatch(let mismatches) = reversed.results[1].status else {
            return XCTFail("Expected mismatch after reference change, got \(reversed.results[1].status)")
        }
        XCTAssertTrue(
            mismatches.contains(
                .videoDisplaySize("640x360", "320x240")
            )
        )
    }

    func testReusingInspectionsWithCompatibleReferencePasses() async throws {
        let a = try Self.fixtureURL("compat_a.mov")
        let b = try Self.fixtureURL("compat_b.mov")
        let loaded = await AssetInspector.preflight(urls: [a, b])
        let recomputed = AssetInspector.preflight(reusing: loaded.results)
        XCTAssertTrue(recomputed.canExport)
        XCTAssertEqual(recomputed.results.map(\.url), [a, b])
    }

    func testAssertCompatibleForExportThrowsForMismatch() async throws {
        let a = try Self.fixtureURL("compat_a.mov")
        let bad = try Self.fixtureURL("incompat_size.mov")

        do {
            try await AssetInspector.assertCompatibleForExport(urls: [a, bad])
            XCTFail("Expected incompatible throw")
        } catch let AssetInspectorError.incompatible(reasons) {
            XCTAssertFalse(reasons.isEmpty)
            XCTAssertTrue(reasons.contains(where: { $0.hasPrefix("file[1]:") }))
        }
    }

    func testAssertCompatibleForExportSucceedsForCompatiblePair() async throws {
        let a = try Self.fixtureURL("compat_a.mov")
        let b = try Self.fixtureURL("compat_b.mov")
        try await AssetInspector.assertCompatibleForExport(urls: [a, b])
    }

    func testJoinExporterPreflightUsesRowAddressableReasons() async throws {
        let a = try Self.fixtureURL("compat_a.mov")
        let bad = try Self.fixtureURL("incompat_fps.mov")

        do {
            try await JoinExporter.preflightCompatibility(inputURLs: [a, bad])
            XCTFail("Expected JoinExporterError.incompatible")
        } catch let JoinExporterError.incompatible(reasons) {
            XCTAssertTrue(reasons.contains(where: { $0.contains("file[1]:") && $0.contains("frame duration") }))
        }
    }

    func testInspectDoesNotBlockMainActor() async throws {
        let url = try Self.ensureCompatFixture()
        let finished = expectation(description: "inspection finished")

        Task { @MainActor in
            // Pump the main actor while inspection runs so a blocking load would stall this hop.
            var pumped = false
            Task.detached {
                _ = await AssetInspector.inspect(url)
                finished.fulfill()
            }
            await Task.yield()
            pumped = true
            XCTAssertTrue(pumped)
        }

        await fulfillment(of: [finished], timeout: 30)
    }

    // MARK: - Fixtures

    private static func fixtureURL(_ name: String) throws -> URL {
        let url = repoRoot().appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        _ = try ensureCompatFixture()
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Missing fixture \(name)")
        }
        return url
    }

    private static func ensureCompatFixture() throws -> URL {
        let fixturesDir = repoRoot().appendingPathComponent("Fixtures", isDirectory: true)
        let url = fixturesDir.appendingPathComponent("compat_a.mov")
        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        process.arguments = [
            repoRoot().appendingPathComponent("Scripts/generate_spike_fixtures.swift").path,
            fixturesDir.path,
        ]
        process.currentDirectoryURL = repoRoot()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Could not generate Fixtures/compat_a.mov for AssetInspector tests")
        }
        return url
    }

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MoviesConnectorTests
            .deletingLastPathComponent() // repo root
    }
}
