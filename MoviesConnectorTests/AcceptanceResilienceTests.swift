import AVFoundation
import XCTest
@testable import MoviesConnector

/// Issue #7 gap-fill: early/late cancel, moved/unreadable after inspection, passthrough evidence.
final class AcceptanceResilienceTests: XCTestCase {
    private var outputDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        JoinExporter.resetForTesting()
        AssetInspector.resetForTesting()
        outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("movies-connector-acceptance-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        installPermissiveAccessMocks()
    }

    override func tearDown() {
        JoinExporter.resetForTesting()
        AssetInspector.resetForTesting()
        UserSelectedURLAccess.resetForTesting()
        SecurityScopedAccess.resetAccessorsForTesting()
        if let outputDirectory {
            try? FileManager.default.removeItem(at: outputDirectory)
        }
        super.tearDown()
    }

    // MARK: - Compatibility matrix (local)

    func testCompatibleLocalInputsExport() async throws {
        let a = try await TestMovieFixtures.url(named: "compat_a.mov")
        let b = try await TestMovieFixtures.url(named: "compat_b.mov")
        let output = outputDirectory.appendingPathComponent("compat-join.mov")

        let result = try await JoinExporter.join(inputURLs: [a, b], outputURL: output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(result.inputCount, 2)
    }

    func testIncompatibleLocalInputsRejectedWithPerRowReasons() async throws {
        let a = try await TestMovieFixtures.url(named: "compat_a.mov")
        let size = try await TestMovieFixtures.url(named: "incompat_size.mov")
        let fps = try await TestMovieFixtures.url(named: "incompat_fps.mov")
        let output = outputDirectory.appendingPathComponent("should-not-exist.mov")

        do {
            _ = try await JoinExporter.join(inputURLs: [a, size], outputURL: output)
            XCTFail("Expected size mismatch refusal")
        } catch let JoinExporterError.incompatible(reasons) {
            XCTAssertTrue(reasons.contains(where: { $0.contains("file[1]:") && $0.contains("display size") }))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))

        do {
            _ = try await JoinExporter.join(inputURLs: [a, fps], outputURL: output)
            XCTFail("Expected fps mismatch refusal")
        } catch let JoinExporterError.incompatible(reasons) {
            XCTAssertTrue(reasons.contains(where: { $0.contains("file[1]:") && $0.contains("frame duration") }))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    // MARK: - Cancellation early / late

    func testEarlyCancellationLeavesNoPartialOutput() async throws {
        let a = try await TestMovieFixtures.makeTemporaryCompatibleMovie(frameCount: 300)
        let b = try await TestMovieFixtures.makeTemporaryCompatibleMovie(frameCount: 300)
        let output = outputDirectory.appendingPathComponent("early-cancel.mov")

        final class Box: @unchecked Sendable {
            var task: Task<JoinExporter.Result, Error>?
            var tempURL: URL?
            var maxProgress: Double = 0
        }
        let box = Box()
        JoinExporter.didCreateTempURLForTesting = { url in box.tempURL = url }

        box.task = Task {
            try await JoinExporter.join(inputURLs: [a, b], outputURL: output) { progress in
                box.maxProgress = max(box.maxProgress, progress)
                // Cancel as soon as export progress starts (early).
                if progress > 0.02 && progress < 0.35 {
                    box.task?.cancel()
                }
            }
        }

        do {
            _ = try await box.task!.value
            XCTFail("Expected early cancellation")
        } catch JoinExporterError.cancelled {
            // expected
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        if let tempURL = box.tempURL {
            XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path))
        }
        XCTAssertLessThan(box.maxProgress, 0.9, "Early cancel should trip before late progress")
    }

    func testLateCancellationAtCommitLeavesNoPartialOutput() async throws {
        let a = try await TestMovieFixtures.url(named: "compat_a.mov")
        let b = try await TestMovieFixtures.url(named: "compat_b.mov")
        let output = outputDirectory.appendingPathComponent("late-cancel.mov")
        let marker = "late-cancel-destination"
        try marker.write(to: output, atomically: true, encoding: .utf8)

        final class Box: @unchecked Sendable {
            var task: Task<JoinExporter.Result, Error>?
            var tempURL: URL?
        }
        let box = Box()
        JoinExporter.didCreateTempURLForTesting = { url in box.tempURL = url }
        // Export body completes; cancel at the commit boundary (late).
        JoinExporter.exportBodyForTesting = { tempURL in
            try FileManager.default.copyItem(at: a, to: tempURL)
        }
        JoinExporter.beforeCommitForTesting = {
            box.task?.cancel()
            throw CancellationError()
        }

        box.task = Task {
            try await JoinExporter.join(inputURLs: [a, b], outputURL: output)
        }

        do {
            _ = try await box.task!.value
            XCTFail("Expected late/commit cancellation")
        } catch JoinExporterError.cancelled {
            // expected
        }

        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), marker)
        if let tempURL = box.tempURL {
            XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path))
        }
    }

    // MARK: - Moved / unreadable after inspection

    func testMovedInputAfterInspectionRefusedWithoutOutput() async throws {
        let a = try await TestMovieFixtures.url(named: "compat_a.mov")
        let mutable = outputDirectory.appendingPathComponent("will-move.mov")
        try FileManager.default.copyItem(
            at: try await TestMovieFixtures.url(named: "compat_b.mov"),
            to: mutable
        )
        let output = outputDirectory.appendingPathComponent("moved-join.mov")

        let report = try await AssetInspector.preflight(urls: [a, mutable])
        XCTAssertTrue(report.canExport, "Precondition: pair must be compatible before move")

        let relocated = outputDirectory.appendingPathComponent("relocated.mov")
        try FileManager.default.moveItem(at: mutable, to: relocated)

        do {
            _ = try await JoinExporter.join(inputURLs: [a, mutable], outputURL: output)
            XCTFail("Expected refusal after input was moved")
        } catch JoinExporterError.incompatible {
            // expected — missing/unreadable at join time
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: relocated.path))
    }

    func testUnreadableInputAfterInspectionRefusedWithoutOutput() async throws {
        let a = try await TestMovieFixtures.url(named: "compat_a.mov")
        let mutable = outputDirectory.appendingPathComponent("will-lock.mov")
        try FileManager.default.copyItem(
            at: try await TestMovieFixtures.url(named: "compat_b.mov"),
            to: mutable
        )
        let output = outputDirectory.appendingPathComponent("unreadable-join.mov")

        let report = try await AssetInspector.preflight(urls: [a, mutable])
        XCTAssertTrue(report.canExport)

        // Replace with a zero-byte non-media file so AVFoundation cannot read tracks.
        try Data().write(to: mutable)

        do {
            _ = try await JoinExporter.join(inputURLs: [a, mutable], outputURL: output)
            XCTFail("Expected refusal for unreadable input")
        } catch JoinExporterError.incompatible {
            // expected
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    // MARK: - Passthrough / no re-encode evidence

    func testPassthroughKeepsCodecAndDurationWithinOneFrame() async throws {
        let a = try await TestMovieFixtures.url(named: "compat_a.mov")
        let b = try await TestMovieFixtures.url(named: "compat_b.mov")
        let output = outputDirectory.appendingPathComponent("passthrough.mov")

        let signatureA = try await AssetInspector.makeSignature(for: a)
        let durationA = try await AVURLAsset(url: a).load(.duration)
        let durationB = try await AVURLAsset(url: b).load(.duration)
        let expected = CMTimeAdd(durationA, durationB)

        let result = try await JoinExporter.join(inputURLs: [a, b], outputURL: output)

        let outAsset = AVURLAsset(url: output)
        let outTracks = try await outAsset.loadTracks(withMediaType: .video)
        let outTrack = try XCTUnwrap(outTracks.first)
        let outFormats = try await outTrack.load(.formatDescriptions)
        let outCodec = fourCC(outFormats.first)

        XCTAssertEqual(outCodec, signatureA.videoCodec)
        XCTAssertEqual(signatureA.videoCodec, "avc1")

        let frameDuration = try await outTrack.load(.minFrameDuration)
        let frameSeconds = frameDuration.isValid && frameDuration.seconds > 0
            ? frameDuration.seconds
            : 1.0 / 30.0
        let delta = abs(result.outputDuration.seconds - expected.seconds)
        XCTAssertLessThanOrEqual(delta, frameSeconds + 0.000_5)

        // Exporter is hard-wired to AVAssetExportPresetPassthrough (see JoinExporter).
        // Matching codec + duration within one frame is the runtime evidence of no re-encode.
        XCTAssertEqual(CMTimeCompare(result.expectedDuration, expected), 0)
    }

    func testLongerCompatibleJoinCompletesAndCleansNothingOnSuccess() async throws {
        let a = try await TestMovieFixtures.makeTemporaryCompatibleMovie(frameCount: 90)
        let b = try await TestMovieFixtures.makeTemporaryCompatibleMovie(frameCount: 90)
        let c = try await TestMovieFixtures.makeTemporaryCompatibleMovie(frameCount: 90)
        let output = outputDirectory.appendingPathComponent("long-join.mov")

        let result = try await JoinExporter.join(inputURLs: [a, b, c], outputURL: output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(result.inputCount, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: c.path))

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)
        XCTAssertFalse(leftovers.contains { $0.hasPrefix(".movies-connector-staging-") })
        XCTAssertFalse(leftovers.contains { $0.hasPrefix(".movies-connector-backup-") })
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

    private func fourCC(_ format: CMFormatDescription?) -> String? {
        guard let format else { return nil }
        let value = CMFormatDescriptionGetMediaSubType(format)
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
        let raw = String(bytes: bytes, encoding: .isoLatin1) ?? ""
        return raw.trimmingCharacters(in: .whitespaces).lowercased()
    }
}
