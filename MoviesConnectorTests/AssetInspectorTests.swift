import AVFoundation
import XCTest
@testable import MoviesConnector

final class AssetInspectorTests: XCTestCase {
    override func tearDown() {
        AssetInspector.resetForTesting()
        super.tearDown()
    }

    func testVideoTimescaleUsesNaturalTimeScaleNotTimeRangeStart() async throws {
        let fixtureURL = try await TestMovieFixtures.compatA()
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
        let url = try await TestMovieFixtures.compatA()
        let result = try await AssetInspector.inspect(url)

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
        let a = try await TestMovieFixtures.url(named: "compat_a.mov")
        let b = try await TestMovieFixtures.url(named: "compat_b.mov")
        let report = try await AssetInspector.preflight(urls: [a, b])

        XCTAssertTrue(report.canExport)
        XCTAssertEqual(report.results.count, 2)
        XCTAssertEqual(report.results.map(\.url), [a, b])
        XCTAssertEqual(report.results.map(\.index), [0, 1])
        XCTAssertTrue(report.results.allSatisfy { $0.status == .compatible })
        XCTAssertTrue(report.rowReasons.isEmpty)
    }

    func testDisplaySizeMismatchProducesRowAddressableReason() async throws {
        let a = try await TestMovieFixtures.url(named: "compat_a.mov")
        let bad = try await TestMovieFixtures.url(named: "incompat_size.mov")
        let report = try await AssetInspector.preflight(urls: [a, bad])

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
        let a = try await TestMovieFixtures.url(named: "compat_a.mov")
        let bad = try await TestMovieFixtures.url(named: "incompat_fps.mov")
        let report = try await AssetInspector.preflight(urls: [a, bad])

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
        let readable = try await TestMovieFixtures.compatA()

        let report = try await AssetInspector.preflight(urls: [missing, readable])
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
        let a = try await TestMovieFixtures.url(named: "compat_a.mov")
        let b = try await TestMovieFixtures.url(named: "compat_b.mov")
        let size = try await TestMovieFixtures.url(named: "incompat_size.mov")
        let urls = [size, b, a]

        let report = try await AssetInspector.preflight(urls: urls)
        XCTAssertEqual(report.results.map(\.url), urls)
        XCTAssertEqual(report.results.map(\.index), [0, 1, 2])
    }

    func testReferenceChangeRecomputesCompatibility() async throws {
        let a = try await TestMovieFixtures.url(named: "compat_a.mov")
        let size = try await TestMovieFixtures.url(named: "incompat_size.mov")

        let forward = try await AssetInspector.preflight(urls: [a, size])
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
        let a = try await TestMovieFixtures.url(named: "compat_a.mov")
        let b = try await TestMovieFixtures.url(named: "compat_b.mov")
        let loaded = try await AssetInspector.preflight(urls: [a, b])
        let recomputed = AssetInspector.preflight(reusing: loaded.results)
        XCTAssertTrue(recomputed.canExport)
        XCTAssertEqual(recomputed.results.map(\.url), [a, b])
    }

    func testAssertCompatibleForExportThrowsForMismatch() async throws {
        let a = try await TestMovieFixtures.url(named: "compat_a.mov")
        let bad = try await TestMovieFixtures.url(named: "incompat_size.mov")

        do {
            try await AssetInspector.assertCompatibleForExport(urls: [a, bad])
            XCTFail("Expected incompatible throw")
        } catch let AssetInspectorError.incompatible(reasons) {
            XCTAssertFalse(reasons.isEmpty)
            XCTAssertTrue(reasons.contains(where: { $0.hasPrefix("file[1]:") }))
        }
    }

    func testAssertCompatibleForExportSucceedsForCompatiblePair() async throws {
        let a = try await TestMovieFixtures.url(named: "compat_a.mov")
        let b = try await TestMovieFixtures.url(named: "compat_b.mov")
        try await AssetInspector.assertCompatibleForExport(urls: [a, b])
    }

    func testJoinExporterPreflightUsesRowAddressableReasons() async throws {
        let a = try await TestMovieFixtures.url(named: "compat_a.mov")
        let bad = try await TestMovieFixtures.url(named: "incompat_fps.mov")

        do {
            try await JoinExporter.preflightCompatibility(inputURLs: [a, bad])
            XCTFail("Expected JoinExporterError.incompatible")
        } catch let JoinExporterError.incompatible(reasons) {
            XCTAssertTrue(reasons.contains(where: { $0.contains("file[1]:") && $0.contains("frame duration") }))
        }
    }

    func testInspectDoesNotBlockMainActor() async throws {
        let url = try await TestMovieFixtures.compatA()

        let heartbeatBeforeCompletion = expectation(
            description: "MainActor heartbeat progressed before inspection completed"
        )
        let inspectionFinished = expectation(description: "inspection finished")

        // Launch from MainActor, then wait off the actor so fulfillment does not deadlock.
        Task { @MainActor in
            final class Flag: @unchecked Sendable {
                var inspectionCompleted = false
            }
            let flag = Flag()

            let inspection = Task { @MainActor in
                _ = try await AssetInspector.inspect(url)
                flag.inspectionCompleted = true
                inspectionFinished.fulfill()
            }

            let heartbeat = Task { @MainActor in
                // Yield so `inspection` can start and hit its first async suspension.
                await Task.yield()
                await Task.yield()
                // If inspect blocked the MainActor through completion, this hop would only
                // run after `inspectionCompleted == true`, and we would fail the ordering check.
                if !flag.inspectionCompleted {
                    heartbeatBeforeCompletion.fulfill()
                } else {
                    XCTFail(
                        "Inspection completed before MainActor heartbeat could run; cannot prove non-blocking"
                    )
                }
            }

            _ = try await inspection.value
            _ = await heartbeat.value
        }

        await fulfillment(
            of: [heartbeatBeforeCompletion, inspectionFinished],
            timeout: 30,
            enforceOrder: true
        )
    }

    func testPhotosSideCarTracksAreIgnorableForPassthrough() {
        XCTAssertTrue(AssetInspector.isPassthroughIgnorableTrack(.metadata))
        XCTAssertTrue(AssetInspector.isPassthroughIgnorableTrack(.timecode))
        XCTAssertFalse(AssetInspector.isPassthroughIgnorableTrack(.text))
        XCTAssertFalse(AssetInspector.isPassthroughIgnorableTrack(.closedCaption))
        XCTAssertFalse(AssetInspector.isPassthroughIgnorableTrack(.subtitle))
        XCTAssertFalse(AssetInspector.isPassthroughIgnorableTrack(.video))
        XCTAssertFalse(AssetInspector.isPassthroughIgnorableTrack(.audio))
        XCTAssertFalse(AssetInspector.isPassthroughIgnorableTrack(.muxed))
    }
}
