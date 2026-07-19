import AVFoundation
import AppKit
import XCTest
@testable import MoviesConnector

final class JoinExporterTests: XCTestCase {
    private var outputDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        JoinExporter.resetForTesting()
        AssetInspector.resetForTesting()
        outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("movies-connector-join-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        installPermissiveAccessMocks()
    }

    override func tearDown() {
        JoinExporter.resetForTesting()
        AssetInspector.resetForTesting()
        UserSelectedURLAccess.resetForTesting()
        if let outputDirectory {
            try? FileManager.default.removeItem(at: outputDirectory)
        }
        super.tearDown()
    }

    func testCompatibleJoinSucceedsWithExactOrderAndDurationWithinOneFrame() async throws {
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

        // Exact order: first half is blue (compat_a), second half is green (compat_b).
        let firstSampleTime = CMTimeMultiplyByFloat64(durationA, multiplier: 0.5)
        let secondSampleTime = CMTimeAdd(durationA, CMTimeMultiplyByFloat64(durationB, multiplier: 0.5))
        let firstColor = try await averageCenterColor(of: output, at: firstSampleTime)
        let secondColor = try await averageCenterColor(of: output, at: secondSampleTime)
        XCTAssertTrue(
            firstColor.blue > firstColor.green + 0.08,
            "Expected blue-dominant first segment, got \(firstColor)"
        )
        XCTAssertTrue(
            secondColor.green > secondColor.blue + 0.08,
            "Expected green-dominant second segment, got \(secondColor)"
        )

        XCTAssertFalse(progressSamples.isEmpty)
        XCTAssertEqual(progressSamples.first, 0)
        XCTAssertEqual(progressSamples.last, 1)
        for index in 1..<progressSamples.count {
            XCTAssertGreaterThanOrEqual(progressSamples[index], progressSamples[index - 1])
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))
    }

    func testOutputCollidingWithInputRejectedBeforeWrite() async throws {
        let a = try await TestMovieFixtures.url(named: "compat_a.mov")
        let b = try await TestMovieFixtures.url(named: "compat_b.mov")
        let inputData = try Data(contentsOf: a)

        // Same path (standardized) collision.
        do {
            _ = try await JoinExporter.join(inputURLs: [a, b], outputURL: a)
            XCTFail("Expected outputCollidesWithInput")
        } catch JoinExporterError.outputCollidesWithInput {
            // expected
        }
        XCTAssertEqual(try Data(contentsOf: a), inputData)

        // Symlink to an input as output destination.
        let link = outputDirectory.appendingPathComponent("link-to-a.mov")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: a)
        do {
            _ = try await JoinExporter.join(inputURLs: [a, b], outputURL: link)
            XCTFail("Expected outputCollidesWithInput for symlink")
        } catch JoinExporterError.outputCollidesWithInput {
            // expected
        }
        XCTAssertEqual(try Data(contentsOf: a), inputData)

        // Non-standardized path that resolves to the same file.
        let alias = a
            .deletingLastPathComponent()
            .appendingPathComponent(".", isDirectory: true)
            .appendingPathComponent(a.lastPathComponent)
        do {
            _ = try await JoinExporter.join(inputURLs: [a, b], outputURL: alias)
            XCTFail("Expected outputCollidesWithInput for standardized path")
        } catch JoinExporterError.outputCollidesWithInput {
            // expected
        }
        XCTAssertEqual(try Data(contentsOf: a), inputData)
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

    func testPreflightRaceChangeRefusesBeforeWrite() async throws {
        let a = try await TestMovieFixtures.url(named: "compat_a.mov")
        let mutable = outputDirectory.appendingPathComponent("race-input.mov")
        try FileManager.default.copyItem(
            at: try await TestMovieFixtures.url(named: "compat_b.mov"),
            to: mutable
        )
        let output = outputDirectory.appendingPathComponent("race-out.mov")

        // Replace the second input with an incompatible file after the caller thought it was OK.
        try FileManager.default.removeItem(at: mutable)
        try FileManager.default.copyItem(
            at: try await TestMovieFixtures.url(named: "incompat_fps.mov"),
            to: mutable
        )

        do {
            _ = try await JoinExporter.join(inputURLs: [a, mutable], outputURL: output)
            XCTFail("Expected incompatible refusal after race change")
        } catch JoinExporterError.incompatible {
            // expected
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
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

    func testCancellationRemovesPartialJobTempAndPreservesDestination() async throws {
        let a = try await TestMovieFixtures.makeTemporaryCompatibleMovie(frameCount: 240)
        let b = try await TestMovieFixtures.makeTemporaryCompatibleMovie(frameCount: 240)
        let output = outputDirectory.appendingPathComponent("cancel-target.mov")
        let marker = "do-not-delete"
        try marker.write(to: output, atomically: true, encoding: .utf8)

        final class JoinBox: @unchecked Sendable {
            var task: Task<JoinExporter.Result, Error>?
            var tempURL: URL?
        }
        let box = JoinBox()
        JoinExporter.didCreateTempURLForTesting = { url in
            box.tempURL = url
        }

        box.task = Task {
            try await JoinExporter.join(inputURLs: [a, b], outputURL: output) { progress in
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
        }

        let remaining = try String(contentsOf: output, encoding: .utf8)
        XCTAssertEqual(remaining, marker, "Pre-existing destination must not be replaced on cancel")
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))
        if let tempURL = box.tempURL {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: tempURL.path),
                "Job temp \(tempURL.lastPathComponent) must be cleaned up"
            )
        } else {
            XCTFail("Expected temp URL to be observed")
        }
    }

    func testCommitBoundaryCancelDoesNotInstallAndCleansTemp() async throws {
        let a = try await TestMovieFixtures.url(named: "compat_a.mov")
        let b = try await TestMovieFixtures.url(named: "compat_b.mov")
        let output = outputDirectory.appendingPathComponent("commit-cancel.mov")
        let marker = "keep-me"
        try marker.write(to: output, atomically: true, encoding: .utf8)

        final class Box: @unchecked Sendable {
            var task: Task<JoinExporter.Result, Error>?
            var tempURL: URL?
        }
        let box = Box()
        JoinExporter.didCreateTempURLForTesting = { url in box.tempURL = url }
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
            XCTFail("Expected cancelled at commit boundary")
        } catch JoinExporterError.cancelled {
            // expected
        }

        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), marker)
        if let tempURL = box.tempURL {
            XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path))
        } else {
            XCTFail("Expected temp URL")
        }
    }

    func testInstallRaceDoesNotDeleteExternalDestinationMarker() async throws {
        let a = try await TestMovieFixtures.url(named: "compat_a.mov")
        let b = try await TestMovieFixtures.url(named: "compat_b.mov")
        let output = outputDirectory.appendingPathComponent("race-dest.mov")
        let marker = "external-owner-marker"

        JoinExporter.exportBodyForTesting = { tempURL in
            try FileManager.default.copyItem(at: a, to: tempURL)
        }
        // After the exporter samples "destination missing", plant a third-party file.
        JoinExporter.afterDestinationExistenceCheckForTesting = { destination in
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: destination.path),
                "Precondition: destination should be absent at existence check"
            )
            try marker.write(to: destination, atomically: true, encoding: .utf8)
        }

        do {
            _ = try await JoinExporter.join(inputURLs: [a, b], outputURL: output)
            XCTFail("Expected install failure when external marker appears")
        } catch JoinExporterError.exportFailed {
            // expected — rename/replace cannot claim a third-party file
        }

        XCTAssertEqual(
            try String(contentsOf: output, encoding: .utf8),
            marker,
            "Third-party destination created after existence check must not be deleted"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)
        XCTAssertFalse(
            leftovers.contains { $0.hasPrefix(".movies-connector-staging-") },
            "Failed commit must clean job staging, not the final URL"
        )
    }

    func testAccessPhaseCancellationNormalizesToCancelled() async throws {
        let a = try await TestMovieFixtures.url(named: "compat_a.mov")
        let b = try await TestMovieFixtures.url(named: "compat_b.mov")
        let output = outputDirectory.appendingPathComponent("access-cancel.mov")

        UserSelectedURLAccess.ubiquitousItemStateForTesting = { _ in
            UbiquitousItemState(
                isUbiquitous: true,
                downloadingStatus: .downloaded,
                isDownloading: true,
                downloadingErrorDescription: nil,
                isReadable: false
            )
        }
        UserSelectedURLAccess.startDownloadingForTesting = { _ in }
        UserSelectedURLAccess.sleepForTesting = { _ in
            throw CancellationError()
        }

        do {
            _ = try await JoinExporter.join(inputURLs: [a, b], outputURL: output)
            XCTFail("Expected cancelled from prepared-access cancellation")
        } catch JoinExporterError.cancelled {
            // expected — raw CancellationError before body must become .cancelled
        }
    }

    func testPreflightPhaseCancellationNormalizesToCancelled() async throws {
        let a = try await TestMovieFixtures.url(named: "compat_a.mov")
        let b = try await TestMovieFixtures.url(named: "compat_b.mov")
        let output = outputDirectory.appendingPathComponent("preflight-cancel.mov")

        AssetInspector.beforeLoadInspectionForTesting = { _ in
            throw CancellationError()
        }

        do {
            _ = try await JoinExporter.join(inputURLs: [a, b], outputURL: output)
            XCTFail("Expected cancelled from preflight cancellation")
        } catch JoinExporterError.cancelled {
            // expected — must not surface as .incompatible / .unreadable
        } catch JoinExporterError.incompatible {
            XCTFail("Preflight CancellationError must not map to incompatible")
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testBuildPhaseCancellationNormalizesToCancelled() async throws {
        let a = try await TestMovieFixtures.url(named: "compat_a.mov")
        let b = try await TestMovieFixtures.url(named: "compat_b.mov")
        let output = outputDirectory.appendingPathComponent("build-cancel.mov")

        JoinExporter.beforeBuildTracksLoadForTesting = {
            throw CancellationError()
        }

        do {
            _ = try await JoinExporter.join(inputURLs: [a, b], outputURL: output)
            XCTFail("Expected cancelled from build-phase cancellation")
        } catch JoinExporterError.cancelled {
            // expected — tracks-load CancellationError must not become .incompatible
        } catch JoinExporterError.incompatible {
            XCTFail("Build CancellationError must not map to incompatible")
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testTransactionalInstallRemovesPartialNewDestinationOnMoveFailure() async throws {
        let a = try await TestMovieFixtures.url(named: "compat_a.mov")
        let b = try await TestMovieFixtures.url(named: "compat_b.mov")

        // Parent path is a file, so createDirectory / moveItem fails. Destination must not remain.
        let blocker = outputDirectory.appendingPathComponent("not-a-directory")
        XCTAssertTrue(FileManager.default.createFile(atPath: blocker.path, contents: Data("x".utf8)))
        let output = blocker.appendingPathComponent("out.mov")

        do {
            _ = try await JoinExporter.join(inputURLs: [a, b], outputURL: output)
            XCTFail("Expected export/install failure")
        } catch JoinExporterError.exportFailed {
            // expected
        } catch JoinExporterError.diskFull {
            // acceptable if the platform surfaces ENOSPC-style codes
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))
    }

    func testInstallFailurePreservesPreexistingDestination() async throws {
        let a = try await TestMovieFixtures.url(named: "compat_a.mov")
        let b = try await TestMovieFixtures.url(named: "compat_b.mov")
        let output = outputDirectory.appendingPathComponent("existing.mov")
        let marker = "original-destination"
        try marker.write(to: output, atomically: true, encoding: .utf8)

        JoinExporter.exportBodyForTesting = { tempURL in
            try FileManager.default.copyItem(at: a, to: tempURL)
        }
        JoinExporter.installExportForTesting = { _, _ in
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileWriteUnknownError,
                userInfo: [NSLocalizedDescriptionKey: "replace failed"]
            )
        }

        do {
            _ = try await JoinExporter.join(inputURLs: [a, b], outputURL: output)
            XCTFail("Expected exportFailed")
        } catch JoinExporterError.exportFailed {
            // expected
        }

        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), marker)
    }

    func testExportBodyFailureMapsAndCleansTemp() async throws {
        let a = try await TestMovieFixtures.url(named: "compat_a.mov")
        let b = try await TestMovieFixtures.url(named: "compat_b.mov")
        let output = outputDirectory.appendingPathComponent("export-fail.mov")
        let marker = "untouched"
        try marker.write(to: output, atomically: true, encoding: .utf8)

        final class Box: @unchecked Sendable { var tempURL: URL? }
        let box = Box()
        JoinExporter.didCreateTempURLForTesting = { url in box.tempURL = url }
        JoinExporter.exportBodyForTesting = { tempURL in
            try Data("partial-export".utf8).write(to: tempURL)
            throw NSError(
                domain: AVFoundationErrorDomain,
                code: AVError.Code.exportFailed.rawValue,
                userInfo: [NSLocalizedDescriptionKey: "simulated AV export failure"]
            )
        }

        do {
            _ = try await JoinExporter.join(inputURLs: [a, b], outputURL: output)
            XCTFail("Expected exportFailed")
        } catch JoinExporterError.exportFailed {
            // expected
        }

        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), marker)
        if let tempURL = box.tempURL {
            XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path))
        } else {
            XCTFail("Expected temp URL")
        }
    }

    func testDiskFullErrorsMapFromAVPOSIXAndCocoa() {
        let avDiskFull = NSError(
            domain: AVFoundationErrorDomain,
            code: AVError.Code.diskFull.rawValue,
            userInfo: nil
        )
        XCTAssertEqual(JoinExporter.mapErrorForTesting(avDiskFull), .diskFull)

        let enospc = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC), userInfo: nil)
        XCTAssertEqual(JoinExporter.mapErrorForTesting(enospc), .diskFull)

        let cocoa = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError, userInfo: nil)
        XCTAssertEqual(JoinExporter.mapErrorForTesting(cocoa), .diskFull)

        let wrapped = NSError(
            domain: AVFoundationErrorDomain,
            code: AVError.Code.exportFailed.rawValue,
            userInfo: [NSUnderlyingErrorKey: avDiskFull]
        )
        XCTAssertEqual(JoinExporter.mapErrorForTesting(wrapped), .diskFull)

        XCTAssertEqual(JoinExporter.mapErrorForTesting(CancellationError()), .cancelled)

        let other = NSError(
            domain: AVFoundationErrorDomain,
            code: AVError.Code.exportFailed.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "boom"]
        )
        if case .exportFailed = JoinExporter.mapErrorForTesting(other) {
            // expected
        } else {
            XCTFail("Expected exportFailed for non-disk-full AVError")
        }
    }

    func testJoinSurfacesInjectedDiskFullAsTypedError() async throws {
        let a = try await TestMovieFixtures.url(named: "compat_a.mov")
        let b = try await TestMovieFixtures.url(named: "compat_b.mov")
        let output = outputDirectory.appendingPathComponent("disk-full.mov")

        JoinExporter.exportBodyForTesting = { _ in
            throw NSError(
                domain: AVFoundationErrorDomain,
                code: AVError.Code.diskFull.rawValue,
                userInfo: nil
            )
        }

        do {
            _ = try await JoinExporter.join(inputURLs: [a, b], outputURL: output)
            XCTFail("Expected diskFull")
        } catch JoinExporterError.diskFull {
            // expected
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
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

    private struct RGB: CustomStringConvertible {
        var red: CGFloat
        var green: CGFloat
        var blue: CGFloat
        var description: String { "rgb(\(red), \(green), \(blue))" }
    }

    private func averageCenterColor(of url: URL, at time: CMTime) async throws -> RGB {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let cgImage = try await generator.image(at: time).image

        let width = cgImage.width
        let height = cgImage.height
        let sampleSize = 8
        let originX = max(0, (width - sampleSize) / 2)
        let originY = max(0, (height - sampleSize) / 2)
        let cropRect = CGRect(x: originX, y: originY, width: sampleSize, height: sampleSize)
        guard let cropped = cgImage.cropping(to: cropRect) else {
            throw NSError(domain: "JoinExporterTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Unable to crop sample region",
            ])
        }

        let bytesPerPixel = 4
        let bytesPerRow = sampleSize * bytesPerPixel
        var data = [UInt8](repeating: 0, count: sampleSize * sampleSize * bytesPerPixel)
        guard let context = CGContext(
            data: &data,
            width: sampleSize,
            height: sampleSize,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "JoinExporterTests", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Unable to create sample context",
            ])
        }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))

        var totalR: CGFloat = 0
        var totalG: CGFloat = 0
        var totalB: CGFloat = 0
        let pixelCount = sampleSize * sampleSize
        for index in 0..<pixelCount {
            let offset = index * bytesPerPixel
            totalR += CGFloat(data[offset]) / 255
            totalG += CGFloat(data[offset + 1]) / 255
            totalB += CGFloat(data[offset + 2]) / 255
        }
        return RGB(
            red: totalR / CGFloat(pixelCount),
            green: totalG / CGFloat(pixelCount),
            blue: totalB / CGFloat(pixelCount)
        )
    }
}
