#!/usr/bin/env swift
import AVFoundation
import Foundation

/// Builds a compatible multi-clip acceptance dataset by passthrough-joining a seed
/// clip with itself (AVFoundation only — no FFmpeg).
///
/// Usage:
///   swift Scripts/generate_acceptance_fixtures.swift <outDir> [--preset practical|kpi20]
///   swift Scripts/generate_acceptance_fixtures.swift <outDir> --count 10 --repeats 4 --seed Fixtures/bench_a.mov
///
/// Presets:
///   practical — 10 clips, each = 4× seed (~1.2 GB when seed ≈ 29 MB). Default.
///   kpi20     — 10 clips, each ≈ 2 GB (≈67× 29 MB seed) → ~20 GB total.
///               WARNING: still inherits the seed resolution (typically 720p). The acceptance
///               harness treats this as `surrogate_only` — NOT DESIGN.md target-eligible 4K.

enum AcceptanceFixtureGenerator {
    static func run() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let outPath = args.first(where: { !$0.hasPrefix("-") }) else {
            fputs(
                """
                Usage: swift Scripts/generate_acceptance_fixtures.swift <outDir> [--preset practical|kpi20]
                       swift Scripts/generate_acceptance_fixtures.swift <outDir> --count N --repeats M [--seed PATH]

                """,
                stderr
            )
            exit(2)
        }

        let preset = flagValue("--preset", in: args) ?? "practical"
        var count = Int(flagValue("--count", in: args) ?? "") ?? 0
        var repeats = Int(flagValue("--repeats", in: args) ?? "") ?? 0
        let seedPath = flagValue("--seed", in: args)
            ?? FileManager.default.currentDirectoryPath + "/Fixtures/bench_a.mov"

        switch preset {
        case "practical":
            if count == 0 { count = 10 }
            if repeats == 0 { repeats = 4 }
        case "kpi20":
            if count == 0 { count = 10 }
            if repeats == 0 { repeats = 67 }
            fputs(
                """
                WARNING: preset kpi20 only approximates total bytes (~20 GB). It repeats the
                seed clip and is NOT 4K unless the seed itself is 4K. Acceptance KPI scoring
                requires real 4K×10≈20GB; kpi20 output is workload_class=surrogate_only.

                """,
                stderr
            )
        default:
            fputs("Unknown preset \(preset). Use practical or kpi20.\n", stderr)
            exit(2)
        }
        if count <= 0 || repeats <= 0 {
            fputs("--count and --repeats must be positive.\n", stderr)
            exit(2)
        }

        let outDir = URL(fileURLWithPath: outPath, isDirectory: true)
        let seedURL = URL(fileURLWithPath: seedPath)
        guard FileManager.default.fileExists(atPath: seedURL.path) else {
            fputs(
                """
                Seed missing: \(seedURL.path)
                Generate with: swift Scripts/generate_spike_fixtures.swift Fixtures --bench

                """,
                stderr
            )
            exit(1)
        }

        do {
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            let seedBytes = try fileSize(seedURL)
            print("Seed: \(seedURL.path) (\(seedBytes) bytes)")
            print("Plan: \(count) clips × \(repeats) seed repeats ≈ \(seedBytes * Int64(count * repeats)) bytes")

            // Build one template clip (seed repeated), then copy it N times — identical
            // signatures remain compatible; order markers are validated in XCTest micro-fixtures.
            let template = outDir.appendingPathComponent("_template.mov")
            if FileManager.default.fileExists(atPath: template.path) {
                try FileManager.default.removeItem(at: template)
            }
            let inputs = Array(repeating: seedURL, count: repeats)
            print("Building template (\(repeats)× seed)…")
            try await passthroughJoin(inputs: inputs, output: template)
            let templateBytes = try fileSize(template)
            print("Template: \(templateBytes) bytes")

            var total: Int64 = 0
            for index in 1...count {
                let dest = outDir.appendingPathComponent(String(format: "accept_%02d.mov", index))
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: template, to: dest)
                let bytes = try fileSize(dest)
                total += bytes
                print("Wrote \(dest.lastPathComponent) (\(bytes) bytes)")
            }
            try FileManager.default.removeItem(at: template)

            let manifest = """
            # Acceptance fixtures
            preset=\(preset)
            count=\(count)
            repeats=\(repeats)
            seed=\(seedURL.path)
            seed_bytes=\(seedBytes)
            total_bytes=\(total)
            codec=avc1 (H.264, inherited from seed)
            generated=\(ISO8601DateFormatter().string(from: Date()))
            """
            try manifest.write(
                to: outDir.appendingPathComponent("MANIFEST.txt"),
                atomically: true,
                encoding: .utf8
            )
            print("Done. Total source bytes: \(total) (\(String(format: "%.2f", Double(total) / 1_000_000_000)) GB)")
            print("Manifest: \(outDir.appendingPathComponent("MANIFEST.txt").path)")
        } catch {
            fputs("Fixture generation failed: \(error)\n", stderr)
            exit(1)
        }
    }

    static func flagValue(_ name: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: name), args.index(after: index) < args.endIndex else {
            return nil
        }
        return args[args.index(after: index)]
    }

    static func fileSize(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }

    static func passthroughJoin(inputs: [URL], output: URL) async throws {
        let composition = AVMutableComposition()
        guard let videoComp = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw NSError(domain: "AcceptanceFixtures", code: 1)
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
                    audioComp = composition.addMutableTrack(
                        withMediaType: .audio,
                        preferredTrackID: kCMPersistentTrackID_Invalid
                    )
                }
                try audioComp?.insertTimeRange(range, of: audio, at: cursor)
            }
            cursor = CMTimeAdd(cursor, duration)
        }

        guard let session = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw NSError(domain: "AcceptanceFixtures", code: 2)
        }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("movies-connector-accept-gen-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: temp) }
        try await session.export(to: temp, as: .mov)
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: temp, to: output)
    }
}

await AcceptanceFixtureGenerator.run()
