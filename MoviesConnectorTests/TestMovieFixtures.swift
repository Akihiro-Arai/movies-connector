import AppKit
import AVFoundation
import Foundation
import XCTest

/// In-process H.264 .mov fixture generation for tests (no `Process` / external swift script).
/// Works under the xcodebuild test sandbox where spawning `/usr/bin/swift` is unreliable.
enum TestMovieFixtures {
    private static let gate = Gate()

    struct Spec {
        var name: String
        var width: Int
        var height: Int
        var frameCount: Int
        var fps: Double
        var color: NSColor
        var bitRate: Int
    }

    private static let specs: [Spec] = [
        .init(name: "compat_a", width: 320, height: 240, frameCount: 15, fps: 30, color: .systemBlue, bitRate: 500_000),
        .init(name: "compat_b", width: 320, height: 240, frameCount: 15, fps: 30, color: .systemGreen, bitRate: 500_000),
        .init(name: "incompat_size", width: 640, height: 360, frameCount: 15, fps: 30, color: .systemOrange, bitRate: 500_000),
        .init(name: "incompat_fps", width: 320, height: 240, frameCount: 12, fps: 24, color: .systemPurple, bitRate: 500_000),
    ]

    static func url(named name: String) async throws -> URL {
        let directory = try await gate.ensureGenerated()
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("Fixture \(name) was not generated at \(url.path)")
            throw FixtureError.missing(name)
        }
        return url
    }

    static func compatA() async throws -> URL {
        try await url(named: "compat_a.mov")
    }

    private actor Gate {
        private var cachedDirectory: URL?
        private var inFlight: Task<URL, Error>?

        func ensureGenerated() async throws -> URL {
            if let cachedDirectory, TestMovieFixtures.allFixturesExist(in: cachedDirectory) {
                return cachedDirectory
            }
            if let inFlight {
                return try await inFlight.value
            }

            let task = Task {
                try await TestMovieFixtures.generateFreshDirectory()
            }
            inFlight = task
            do {
                let directory = try await task.value
                cachedDirectory = directory
                inFlight = nil
                return directory
            } catch {
                inFlight = nil
                throw error
            }
        }
    }

    private static func generateFreshDirectory() async throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("movies-connector-test-fixtures", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for spec in specs {
                let url = directory.appendingPathComponent("\(spec.name).mov")
                try await writeMovie(spec: spec, to: url)
            }
        } catch {
            XCTFail("In-process fixture generation failed: \(error)")
            throw FixtureError.generationFailed(String(describing: error))
        }

        guard allFixturesExist(in: directory) else {
            XCTFail("In-process fixture generation finished but expected .mov files are missing in \(directory.path)")
            throw FixtureError.generationFailed("missing outputs")
        }
        return directory
    }

    private static func allFixturesExist(in directory: URL) -> Bool {
        specs.allSatisfy { spec in
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("\(spec.name).mov").path
            )
        }
    }

    private static func writeMovie(spec: Spec, to url: URL) async throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: spec.width,
            AVVideoHeightKey: spec.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: spec.bitRate,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: spec.width,
                kCVPixelBufferHeightKey as String: spec.height,
            ]
        )

        guard writer.canAdd(input) else {
            throw FixtureError.generationFailed("Cannot add video input")
        }
        writer.add(input)

        guard writer.startWriting() else {
            throw writer.error ?? FixtureError.generationFailed("startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)

        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(spec.fps))
        var frameIndex = 0

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            input.requestMediaDataWhenReady(on: DispatchQueue(label: "test.fixture.writer")) {
                while input.isReadyForMoreMediaData {
                    if frameIndex >= spec.frameCount {
                        input.markAsFinished()
                        writer.finishWriting {
                            if let error = writer.error {
                                continuation.resume(throwing: error)
                            } else {
                                continuation.resume()
                            }
                        }
                        return
                    }

                    do {
                        let buffer = try makePixelBuffer(
                            width: spec.width,
                            height: spec.height,
                            color: spec.color,
                            frameIndex: frameIndex
                        )
                        let time = CMTimeMultiply(frameDuration, multiplier: Int32(frameIndex))
                        if !adaptor.append(buffer, withPresentationTime: time) {
                            throw writer.error ?? FixtureError.generationFailed("append failed")
                        }
                        frameIndex += 1
                    } catch {
                        input.markAsFinished()
                        writer.cancelWriting()
                        continuation.resume(throwing: error)
                        return
                    }
                }
            }
        }
    }

    private static func makePixelBuffer(
        width: Int,
        height: Int,
        color: NSColor,
        frameIndex: Int
    ) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            ] as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer = buffer else {
            throw FixtureError.generationFailed("CVPixelBufferCreate failed")
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw FixtureError.generationFailed("missing pixel base address")
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        guard let context = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw FixtureError.generationFailed("CGContext failed")
        }

        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        context.setFillColor(NSColor.white.withAlphaComponent(0.35).cgColor)
        let stripeHeight = max(4, height / 8)
        let stripeY = (height / 8) * (frameIndex % 8)
        context.fill(CGRect(x: 0, y: stripeY, width: width, height: stripeHeight))

        return pixelBuffer
    }

    enum FixtureError: Error, CustomStringConvertible {
        case missing(String)
        case generationFailed(String)

        var description: String {
            switch self {
            case .missing(let name):
                return "Missing fixture \(name)"
            case .generationFailed(let detail):
                return "Fixture generation failed: \(detail)"
            }
        }
    }
}
