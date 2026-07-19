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
            throw XCTSkip("Could not generate Fixtures/compat_a.mov for timescale test")
        }
        return url
    }

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MoviesConnectorTests
            .deletingLastPathComponent() // repo root
    }
}
