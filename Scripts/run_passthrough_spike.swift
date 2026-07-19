#!/usr/bin/env swift
import AVFoundation
import Foundation

/// Command-line passthrough spike (mirrors JoinExporter). No FFmpeg.
/// Usage:
///   swift Scripts/run_passthrough_spike.swift <out.mov> <in1.mov> <in2.mov> [...]

enum PassthroughSpike {
    static func run() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 3 else {
            fputs("Usage: swift Scripts/run_passthrough_spike.swift <out.mov> <in1.mov> <in2.mov> [...]\n", stderr)
            exit(2)
        }

        let outputURL = URL(fileURLWithPath: args[0])
        let inputURLs = args.dropFirst().map { URL(fileURLWithPath: $0) }

        do {
            let signatures = try await loadSignatures(inputURLs)
            print("Signatures:")
            for (url, signature) in zip(inputURLs, signatures) {
                print("  \(url.lastPathComponent): codec=\(signature.videoCodec ?? "nil") size=\(signature.videoDisplayWidth)x\(signature.videoDisplayHeight) fpsDur=\(signature.frameDurationDescription) audioTracks=\(signature.audioTrackCount)")
            }

            let reference = signatures[0]
            var reasons: [String] = []
            for (index, signature) in signatures.dropFirst().enumerated() {
                reasons.append(contentsOf: mismatchReasons(reference: reference, candidate: signature, index: index + 1))
            }
            if !reasons.isEmpty {
                print("REJECTED before export:")
                reasons.forEach { print("  - \($0)") }
                exit(1)
            }

            let copyBaseline = try measureCopyBaseline(of: inputURLs[0], beside: outputURL)
            print(String(format: "Copy baseline (first input → same volume): %.3fs", copyBaseline))

            let started = DispatchTime.now().uptimeNanoseconds
            try await exportPassthrough(inputs: inputURLs, output: outputURL)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
            print(String(format: "Passthrough join: %.3fs for %d inputs → %@", elapsed, inputURLs.count, outputURL.path))

            let outputAsset = AVURLAsset(url: outputURL)
            let outputDuration = try await outputAsset.load(.duration)
            let inputDurations = try await loadDurations(inputURLs)
            let sum = inputDurations.reduce(CMTime.zero, CMTimeAdd)
            print("Duration sum inputs: \(cmTimeDescription(sum))")
            print("Duration output:     \(cmTimeDescription(outputDuration))")

            // Heuristic: passthrough keeps source sample tables; compare video codec FourCC.
            let outTracks = try await outputAsset.loadTracks(withMediaType: .video)
            let outFormats = try await outTracks[0].load(.formatDescriptions)
            let outCodec = fourCC(outFormats.first)
            print("Output video codec: \(outCodec ?? "nil") (expected same as inputs: \(reference.videoCodec ?? "nil"))")
            if outCodec != reference.videoCodec {
                fputs("Warning: output codec differs from inputs; may indicate re-encode.\n", stderr)
                exit(1)
            }
            print("Spike OK: join completed with matching codec (passthrough evidence).")
        } catch {
            fputs("Spike failed: \(error)\n", stderr)
            exit(1)
        }
    }

    struct Signature {
        var videoCodec: String?
        var videoDisplayWidth: Int
        var videoDisplayHeight: Int
        var frameDuration: CMTime?
        var videoTimescale: Int32?
        var audioTrackCount: Int
        var frameDurationDescription: String {
            guard let frameDuration, frameDuration.isValid else { return "nil" }
            return "\(frameDuration.value)/\(frameDuration.timescale)"
        }
    }

    static func loadSignatures(_ urls: [URL]) async throws -> [Signature] {
        var result: [Signature] = []
        for url in urls {
            let asset = AVURLAsset(url: url)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard let video = videoTracks.first else {
                throw NSError(domain: "Spike", code: 1, userInfo: [NSLocalizedDescriptionKey: "No video in \(url.lastPathComponent)"])
            }
            let naturalSize = try await video.load(.naturalSize)
            let transform = try await video.load(.preferredTransform)
            let display = naturalSize.applying(transform)
            let formats = try await video.load(.formatDescriptions)
            let minFrameDuration = try await video.load(.minFrameDuration)
            let timeRange = try await video.load(.timeRange)
            result.append(
                Signature(
                    videoCodec: fourCC(formats.first),
                    videoDisplayWidth: Int(abs(display.width).rounded()),
                    videoDisplayHeight: Int(abs(display.height).rounded()),
                    frameDuration: minFrameDuration,
                    videoTimescale: timeRange.start.timescale,
                    audioTrackCount: audioTracks.count
                )
            )
        }
        return result
    }

    static func mismatchReasons(reference: Signature, candidate: Signature, index: Int) -> [String] {
        var reasons: [String] = []
        if reference.videoCodec != candidate.videoCodec {
            reasons.append("file[\(index)]: video codec \(reference.videoCodec ?? "nil") vs \(candidate.videoCodec ?? "nil")")
        }
        if reference.videoDisplayWidth != candidate.videoDisplayWidth
            || reference.videoDisplayHeight != candidate.videoDisplayHeight {
            reasons.append(
                "file[\(index)]: display size \(reference.videoDisplayWidth)x\(reference.videoDisplayHeight) vs \(candidate.videoDisplayWidth)x\(candidate.videoDisplayHeight)"
            )
        }
        if reference.frameDuration != candidate.frameDuration {
            reasons.append(
                "file[\(index)]: frame duration \(reference.frameDurationDescription) vs \(candidate.frameDurationDescription)"
            )
        }
        if reference.videoTimescale != candidate.videoTimescale {
            reasons.append("file[\(index)]: video timescale \(String(describing: reference.videoTimescale)) vs \(String(describing: candidate.videoTimescale))")
        }
        if reference.audioTrackCount != candidate.audioTrackCount {
            reasons.append("file[\(index)]: audio track count \(reference.audioTrackCount) vs \(candidate.audioTrackCount)")
        }
        return reasons
    }

    static func exportPassthrough(inputs: [URL], output: URL) async throws {
        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }

        let composition = AVMutableComposition()
        guard let videoComp = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw NSError(domain: "Spike", code: 2)
        }
        var audioComp: AVMutableCompositionTrack?
        var cursor = CMTime.zero

        for url in inputs {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            let range = CMTimeRange(start: .zero, duration: duration)
            let video = try await asset.loadTracks(withMediaType: .video)[0]
            try videoComp.insertTimeRange(range, of: video, at: cursor)
            if let audio = try await asset.loadTracks(withMediaType: .audio).first {
                if audioComp == nil {
                    audioComp = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                }
                try audioComp?.insertTimeRange(range, of: audio, at: cursor)
            }
            cursor = CMTimeAdd(cursor, duration)
        }

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw NSError(domain: "Spike", code: 3, userInfo: [NSLocalizedDescriptionKey: "No export session"])
        }
        try await session.export(to: output, as: .mov)
    }

    static func measureCopyBaseline(of source: URL, beside output: URL) throws -> TimeInterval {
        let dest = output.deletingLastPathComponent().appendingPathComponent("copy-baseline-\(source.lastPathComponent)")
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        let started = DispatchTime.now().uptimeNanoseconds
        try FileManager.default.copyItem(at: source, to: dest)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
        try? FileManager.default.removeItem(at: dest)
        return elapsed
    }

    static func loadDurations(_ urls: [URL]) async throws -> [CMTime] {
        var result: [CMTime] = []
        for url in urls {
            result.append(try await AVURLAsset(url: url).load(.duration))
        }
        return result
    }

    static func fourCC(_ format: CMFormatDescription?) -> String? {
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

    static func cmTimeDescription(_ time: CMTime) -> String {
        String(format: "%.3fs (%d/%d)", CMTimeGetSeconds(time), time.value, time.timescale)
    }
}

await PassthroughSpike.run()
