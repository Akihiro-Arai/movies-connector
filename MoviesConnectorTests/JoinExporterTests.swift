import AVFoundation
import XCTest
@testable import MoviesConnector

final class JoinExporterTests: XCTestCase {
    private var outputDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("movies-connector-join-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        installPermissiveAccessMocks()
    }

    override func tearDown() {
        UserSelectedURLAccess.resetForTesting()
        if let outputDirectory {
            try? FileManager.default.removeItem(at: outputDirectory)
        }
        super.tearDown()
    }

    func testCompatibleJoinSucceedsWithOrderAndDurationWithinOneFrame() async throws {
        let a = try await TestMovieFixtures.url(named: "compat_a.mov")
        let b = try await TestMovieFixtures.url(named: "compat_b.mov")
        let output = outputDirectory.appendingPathComponent("joined.mov")

        let durationA = try await AVURLAsset(url: a).load(.duration)
        let durationB = try await AVURLAsset(url: b).load(.duration)
        let expected = CMTimeAdd(durationA, durationB)

        var progressSamples: [Double] = []
        let result = try await JoinExporter.join(inputURLs: [a, b], outputURL: output) { value in
            progressSamples.append(value)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(result.inputCount, 2)
        XCTAssertEqual(result.outputURL, output)

        let frameDuration = try await primaryFrameDuration(of: a)
        let deltaSeconds = abs(result.outputDuration.seconds - expected.seconds)
        XCTAssertLessThanOrEqual(
            deltaSeconds,
            frameDuration.seconds + 0.000_5,
            "Output duration \(result.outputDuration.seconds)s vs expected \(expected.seconds)s; delta \(deltaSeconds)s > one frame \(frameDuration.seconds)s"
        )
        XCTAssertEqual(CMTimeCompare(result.expectedDuration, expected), 0)

        XCTAssertFalse(progressSamples.isEmpty)
        XCTAssertEqual(progressSamples.first, 0)
        XCTAssertEqual(progressSamples.last, 1)
        for index in 1..<progressSamples.count {
            XCTAssertGreaterThanOrEqual(progressSamples[index], progressSamples[index - 1])
        }

        // Inputs must be preserved.
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))
    }

    func testPreflightRefusalWritesNothingAndPreservesExistingDestination() async throws {
        let a = try await TestMovieFixtures.url(named: "compat_a.mov")
        let bad = try await TestMovieFixtures.url(named: "incompat_size.mov")
        let output = outputDirectory.appendingPathComponent("should-not-write.mov")
        let marker = "pre-existing-destination"
        try marker.write(to: output, atomically: true, encoding: .utf8)

        do {
            _ = try await JoinExporter.join(inputURLs: [a, bad], outputURL: output)
            XCTFail("Expected incompatible preflight refusal")
        } catch let JoinExporterError.incompatible(reasons) {
            XCTAssertTrue(reasons.contains(where: { $0.contains("file[1]:") && $0.contains("display size") }))
        }

        let remaining = try String(contentsOf: output, encoding: .utf8)
        XCTAssertEqual(remaining, marker)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bad.path))
    }

    func testMissingInputRefusedBeforeWrite() async throws {
        let a = try await TestMovieFixtures.url(named: "compat_a.mov")
        let missing = outputDirectory.appendingPathComponent("missing-input.mov")
        let output = outputDirectory.appendingPathComponent("missing-join.mov")

        do {
            _ = try await JoinExporter.join(inputURLs: [a, missing], outputURL: output)
            XCTFail("Expected preflight refusal for missing input")
        } catch JoinExporterError.incompatible {
            // expected
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testCancellationRemovesPartialJobOutputAndPreservesDestination() async throws {
        let a = try await TestMovieFixtures.makeTemporaryCompatibleMovie(frameCount: 240)
        let b = try await TestMovieFixtures.makeTemporaryCompatibleMovie(frameCount: 240)
        let output = outputDirectory.appendingPathComponent("cancel-target.mov")
        let marker = "do-not-delete"
        try marker.write(to: output, atomically: true, encoding: .utf8)

        final class JoinBox: @unchecked Sendable {
            var task: Task<JoinExporter.Result, Error>?
        }
        let box = JoinBox()
        box.task = Task {
            try await JoinExporter.join(inputURLs: [a, b], outputURL: output) { progress in
                // Cancel once passthrough export has started so a temp job file may exist.
                if progress >= 0.06 {
                    box.task?.cancel()
                }
            }
        }

        do {
            _ = try await box.task!.value
            XCTFail("Expected cancellation before successful install")
        } catch JoinExporterError.cancelled {
            // expected
        } catch is CancellationError {
            // acceptable if surfaced before JoinExporter mapping
        }

        let remaining = try String(contentsOf: output, encoding: .utf8)
        XCTAssertEqual(remaining, marker, "Pre-existing destination must not be replaced on cancel")
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: outputDirectory.appendingPathComponent("movies-connector-job-probe").path
            )
        )
    }

    func testExporterFailureLeavesDestinationUntouchedAndPreservesInputs() async throws {
        let a = try await TestMovieFixtures.url(named: "compat_a.mov")
        let b = try await TestMovieFixtures.url(named: "compat_b.mov")

        // Parent path is a file, so install/createDirectory fails after (or during) export setup.
        let blocker = outputDirectory.appendingPathComponent("not-a-directory")
        XCTAssertTrue(FileManager.default.createFile(atPath: blocker.path, contents: Data("x".utf8)))
        let output = blocker.appendingPathComponent("out.mov")

        do {
            _ = try await JoinExporter.join(inputURLs: [a, b], outputURL: output)
            XCTFail("Expected export/install failure")
        } catch JoinExporterError.exportFailed {
            // expected
        } catch JoinExporterError.diskFull {
            // acceptable mapping if the platform surfaces ENOSPC-style codes
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))
    }

    func testPreparedAccessReleasedAfterSuccess() async throws {
        let a = try await TestMovieFixtures.url(named: "compat_a.mov")
        let b = try await TestMovieFixtures.url(named: "compat_b.mov")
        let output = outputDirectory.appendingPathComponent("scoped.mov")

        var started: [URL] = []
        var stopped: [URL] = []
        SecurityScopedAccess.startAccessingForTesting = { url in
            started.append(url)
            return true
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

        _ = try await JoinExporter.join(inputURLs: [a, b], outputURL: output)

        XCTAssertEqual(Set(started), Set([a, b, output]))
        XCTAssertEqual(Set(stopped), Set([a, b, output]))
        XCTAssertEqual(started.count, stopped.count)
    }

    func testPreparedAccessReleasedAfterPreflightFailure() async throws {
        let a = try await TestMovieFixtures.url(named: "compat_a.mov")
        let bad = try await TestMovieFixtures.url(named: "incompat_fps.mov")
        let output = outputDirectory.appendingPathComponent("scoped-fail.mov")

        var stopped: [URL] = []
        SecurityScopedAccess.startAccessingForTesting = { _ in true }
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

        do {
            _ = try await JoinExporter.join(inputURLs: [a, bad], outputURL: output)
            XCTFail("Expected incompatible")
        } catch JoinExporterError.incompatible {
            // expected
        }

        XCTAssertEqual(Set(stopped), Set([a, bad, output]))
    }

    // MARK: - Helpers

    private func installPermissiveAccessMocks() {
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
    }

    private func primaryFrameDuration(of url: URL) async throws -> CMTime {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let minFrameDuration = try await track.load(.minFrameDuration)
        if minFrameDuration.isValid && !minFrameDuration.isIndefinite && minFrameDuration.value > 0 {
            return minFrameDuration
        }
        return CMTime(value: 1, timescale: 30)
    }
}
