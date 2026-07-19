#!/usr/bin/env swift
import AVFoundation
import AppKit
import Foundation

/// Generates H.264 .mov fixtures with AVFoundation (no FFmpeg) for the passthrough spike.
/// Usage:
///   swift Scripts/generate_spike_fixtures.swift [outputDirectory] [--bench]

struct FixtureSpec {
    var name: String
    var width: Int
    var height: Int
    var frameCount: Int
    var fps: Double
    var color: NSColor
    var bitRate: Int
    /// When true, paint per-frame pseudo-noise so H.264 cannot collapse to a few KB.
    var noisy: Bool = false
}

enum FixtureGenerator {
    static func run() async {
        let positional = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("-") }
        let includeBench = CommandLine.arguments.contains("--bench")
        let outputRoot: URL
        if let path = positional.first {
            outputRoot = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            outputRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Fixtures", isDirectory: true)
        }

        try? FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)

        var specs: [FixtureSpec] = [
            .init(name: "compat_a", width: 320, height: 240, frameCount: 15, fps: 30, color: .systemBlue, bitRate: 500_000),
            .init(name: "compat_b", width: 320, height: 240, frameCount: 15, fps: 30, color: .systemGreen, bitRate: 500_000),
            .init(name: "incompat_size", width: 640, height: 360, frameCount: 15, fps: 30, color: .systemOrange, bitRate: 500_000),
            .init(name: "incompat_fps", width: 320, height: 240, frameCount: 12, fps: 24, color: .systemPurple, bitRate: 500_000),
        ]
        if includeBench {
            // Noisy 720p clips so encoded size is large enough for a non-zero SSD copy baseline.
            specs.append(contentsOf: [
                .init(
                    name: "bench_a",
                    width: 1280,
                    height: 720,
                    frameCount: 450,
                    fps: 30,
                    color: .systemTeal,
                    bitRate: 16_000_000,
                    noisy: true
                ),
                .init(
                    name: "bench_b",
                    width: 1280,
                    height: 720,
                    frameCount: 450,
                    fps: 30,
                    color: .systemPink,
                    bitRate: 16_000_000,
                    noisy: true
                ),
            ])
        }

        do {
            for spec in specs {
                let url = outputRoot.appendingPathComponent("\(spec.name).mov")
                try await writeMovie(spec: spec, to: url)
                let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
                print("Wrote \(url.path) (\(bytes) bytes)")
            }
            print("Done. Compatible pair: compat_a.mov + compat_b.mov")
            print("Incompatible pairs: compat_a.mov + incompat_size.mov, compat_a.mov + incompat_fps.mov")
            if includeBench {
                print("Bench pair: bench_a.mov + bench_b.mov")
            }
        } catch {
            fputs("Fixture generation failed: \(error)\n", stderr)
            exit(1)
        }
    }

    static func writeMovie(spec: FixtureSpec, to url: URL) async throws {
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

        let adaptorSourceAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: spec.width,
            kCVPixelBufferHeightKey as String: spec.height,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: adaptorSourceAttributes
        )

        guard writer.canAdd(input) else {
            throw NSError(domain: "FixtureGenerator", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Cannot add video input",
            ])
        }
        writer.add(input)

        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "FixtureGenerator", code: 2)
        }
        writer.startSession(atSourceTime: .zero)

        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(spec.fps))
        var frameIndex = 0

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            input.requestMediaDataWhenReady(on: DispatchQueue(label: "fixture.writer")) {
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
                            frameIndex: frameIndex,
                            noisy: spec.noisy
                        )
                        let time = CMTimeMultiply(frameDuration, multiplier: Int32(frameIndex))
                        if !adaptor.append(buffer, withPresentationTime: time) {
                            throw writer.error ?? NSError(domain: "FixtureGenerator", code: 3)
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

    static func makePixelBuffer(
        width: Int,
        height: Int,
        color: NSColor,
        frameIndex: Int,
        noisy: Bool
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
            throw NSError(domain: "FixtureGenerator", code: 4)
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw NSError(domain: "FixtureGenerator", code: 5)
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        if noisy {
            // Deterministic per-frame noise (xorshift) so encoders cannot collapse the stream.
            var state = UInt64(frameIndex &+ 1) &* 0x9E37_79B9_7F4A_7C15
            let rowBytes = width * 4
            for y in 0..<height {
                let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
                for x in stride(from: 0, to: rowBytes, by: 4) {
                    state ^= state << 13
                    state ^= state >> 7
                    state ^= state << 17
                    let value = UInt8(truncatingIfNeeded: state)
                    row[x] = value
                    row[x + 1] = UInt8(truncatingIfNeeded: state >> 8)
                    row[x + 2] = UInt8(truncatingIfNeeded: state >> 16)
                    row[x + 3] = 255
                }
            }
        } else {
            guard let context = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else {
                throw NSError(domain: "FixtureGenerator", code: 5)
            }

            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))

            context.setFillColor(NSColor.white.withAlphaComponent(0.35).cgColor)
            let stripeHeight = max(4, height / 8)
            let stripeY = (height / 8) * (frameIndex % 8)
            context.fill(CGRect(x: 0, y: stripeY, width: width, height: stripeHeight))
        }

        return pixelBuffer
    }
}

await FixtureGenerator.run()
