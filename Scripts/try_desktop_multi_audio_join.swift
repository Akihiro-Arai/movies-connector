#!/usr/bin/env swift
import AVFoundation
import Foundation

/// Experiment: multi-audio passthrough join with ~6% frame-duration tolerance.
/// Usage:
///   swift Scripts/try_desktop_multi_audio_join.swift [out.mov] [in1.mov ...]

enum Experiment {
    static let frameDurationRelativeTolerance = 0.06

    static func run() async {
        let args = Array(CommandLine.arguments.dropFirst())
        let defaultInputs = [
            "IMG_3501.MOV", "IMG_3502.MOV", "IMG_3503.MOV", "IMG_3514.MOV",
        ].map {
            URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Desktop/movieconnector-debug")
                .appendingPathComponent($0)
        }
        let outputURL: URL
        let inputURLs: [URL]
        if args.isEmpty {
            outputURL = URL(fileURLWithPath: "/tmp/desktop-debug-join-experiment.mov")
            inputURLs = defaultInputs
        } else if args.count >= 2 {
            outputURL = URL(fileURLWithPath: args[0])
            inputURLs = args.dropFirst().map { URL(fileURLWithPath: $0) }
        } else {
            fputs("Usage: swift Scripts/try_desktop_multi_audio_join.swift [out.mov in1.mov ...]\n", stderr)
            exit(2)
        }

        for url in inputURLs where !FileManager.default.fileExists(atPath: url.path) {
            fputs("Missing input: \(url.path)\n", stderr)
            exit(2)
        }

        do {
            let metas = try await loadMetas(inputURLs)
            print("Inputs:")
            for meta in metas {
                print(
                    "  \(meta.url.lastPathComponent): size=\(meta.displayWidth)x\(meta.displayHeight) "
                        + "fpsDur=\(meta.frameDurationLabel) audioTracks=\(meta.audioTrackCount) "
                        + "duration=\(String(format: "%.3fs", meta.duration.seconds))"
                )
            }

            let reference = metas[0]
            var rejects: [String] = []
            for meta in metas.dropFirst() {
                if meta.audioTrackCount != reference.audioTrackCount {
                    rejects.append(
                        "\(meta.url.lastPathComponent): audio count \(meta.audioTrackCount) vs \(reference.audioTrackCount)"
                    )
                }
                if !frameDurationsCompatible(reference.frameDuration, meta.frameDuration) {
                    rejects.append(
                        "\(meta.url.lastPathComponent): frame duration \(reference.frameDurationLabel) vs \(meta.frameDurationLabel)"
                    )
                } else if reference.frameDurationLabel != meta.frameDurationLabel {
                    print(
                        "  note: tolerated frame duration \(reference.frameDurationLabel) vs \(meta.frameDurationLabel)"
                    )
                }
            }
            if !rejects.isEmpty {
                print("REJECTED by tolerance preflight:")
                rejects.forEach { print("  - \($0)") }
                exit(1)
            }
            print("Preflight OK (multi-audio + frame-duration tolerance \(Int(frameDurationRelativeTolerance * 100))%).")

            let started = DispatchTime.now().uptimeNanoseconds
            try await exportPassthrough(inputs: inputURLs, output: outputURL)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000

            let outAsset = AVURLAsset(url: outputURL)
            let outDuration = try await outAsset.load(.duration)
            let outAudio = try await outAsset.loadTracks(withMediaType: .audio)
            let outVideo = try await outAsset.loadTracks(withMediaType: .video)
            print(String(format: "Join OK in %.3fs → %@", elapsed, outputURL.path))
            print(
                "Output: duration=\(String(format: "%.3fs", outDuration.seconds)) "
                    + "videoTracks=\(outVideo.count) audioTracks=\(outAudio.count)"
            )
        } catch {
            fputs("FAILED: \(error)\n", stderr)
            exit(1)
        }
    }

    struct Meta {
        var url: URL
        var duration: CMTime
        var displayWidth: Int
        var displayHeight: Int
        var frameDuration: CMTime?
        var audioTrackCount: Int
        var frameDurationLabel: String {
            guard let frameDuration, frameDuration.isValid, frameDuration.value > 0 else {
                return "nil"
            }
            return "\(frameDuration.value)/\(frameDuration.timescale)"
        }
    }

    static func loadMetas(_ urls: [URL]) async throws -> [Meta] {
        var result: [Meta] = []
        for url in urls {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            let video = try await asset.loadTracks(withMediaType: .video)[0]
            let audio = try await asset.loadTracks(withMediaType: .audio)
            let naturalSize = try await video.load(.naturalSize)
            let transform = try await video.load(.preferredTransform)
            let display = naturalSize.applying(transform)
            let minFrame = try await video.load(.minFrameDuration)
            let frame: CMTime? =
                (minFrame.isValid && !minFrame.isIndefinite && minFrame.value > 0) ? minFrame : nil
            result.append(
                Meta(
                    url: url,
                    duration: duration,
                    displayWidth: Int(abs(display.width).rounded()),
                    displayHeight: Int(abs(display.height).rounded()),
                    frameDuration: frame,
                    audioTrackCount: audio.count
                )
            )
        }
        return result
    }

    static func frameDurationsCompatible(_ lhs: CMTime?, _ rhs: CMTime?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (left?, right?):
            let a = left.seconds
            let b = right.seconds
            guard a > 0, b > 0 else { return left == right }
            return abs(a - b) / max(a, b) <= frameDurationRelativeTolerance
        default:
            return false
        }
    }

    static func exportPassthrough(inputs: [URL], output: URL) async throws {
        let composition = AVMutableComposition()
        guard
            let videoComp = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
        else {
            throw NSError(domain: "Experiment", code: 1)
        }

        var audioComps: [AVMutableCompositionTrack] = []
        var expectedAudioCount: Int?
        var cursor = CMTime.zero

        for url in inputs {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            let range = CMTimeRange(start: .zero, duration: duration)
            let video = try await asset.loadTracks(withMediaType: .video)[0]
            let audios = try await asset.loadTracks(withMediaType: .audio)
            try videoComp.insertTimeRange(range, of: video, at: cursor)
            if let transform = try? await video.load(.preferredTransform) {
                videoComp.preferredTransform = transform
            }

            if let expectedAudioCount {
                guard audios.count == expectedAudioCount else {
                    throw NSError(
                        domain: "Experiment",
                        code: 2,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "audio count mismatch in \(url.lastPathComponent)",
                        ]
                    )
                }
            } else {
                expectedAudioCount = audios.count
                for _ in audios.indices {
                    guard
                        let track = composition.addMutableTrack(
                            withMediaType: .audio,
                            preferredTrackID: kCMPersistentTrackID_Invalid
                        )
                    else {
                        throw NSError(domain: "Experiment", code: 3)
                    }
                    audioComps.append(track)
                }
            }

            for (index, audio) in audios.enumerated() {
                try audioComps[index].insertTimeRange(range, of: audio, at: cursor)
            }
            cursor = CMTimeAdd(cursor, duration)
        }

        guard
            let session = AVAssetExportSession(
                asset: composition,
                presetName: AVAssetExportPresetPassthrough
            )
        else {
            throw NSError(domain: "Experiment", code: 4)
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("desktop-join-exp-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try await session.export(to: tempURL, as: .mov)

        if FileManager.default.fileExists(atPath: output.path) {
            _ = try FileManager.default.replaceItemAt(output, withItemAt: tempURL)
        } else {
            try FileManager.default.createDirectory(
                at: output.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(at: tempURL, to: output)
        }
    }
}

await Experiment.run()
