#!/usr/bin/env swift
import AVFoundation
import Foundation

/// Release-oriented acceptance benchmark harness (AVFoundation only — no FFmpeg).
///
/// Modes:
///   --host-info
///   --copy <out.bin> <in1> [in2…]
///   --join <out.mov> <in1> [in2…]
///   --validate <out.mov> <in1> [in2…]
///   --benchmark <workDir> <in1> [in2…]   # warm-up + 5 interleaved copy/join trials
///
/// Compile for cleaner timings:
///   swiftc -O -o /tmp/run_acceptance_benchmark Scripts/run_acceptance_benchmark.swift

enum AcceptanceBenchmark {
    static func run() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let mode = args.first else {
            printUsage()
            exit(2)
        }

        do {
            switch mode {
            case "--host-info":
                printHostInfo()
            case "--copy":
                guard args.count >= 3 else { printUsage(); exit(2) }
                let out = URL(fileURLWithPath: args[1])
                let inputs = args.dropFirst(2).map { URL(fileURLWithPath: $0) }
                let elapsed = try measureCopy(of: inputs, to: out)
                print(String(format: "COPY_SECONDS=%.6f", elapsed))
            case "--join":
                guard args.count >= 3 else { printUsage(); exit(2) }
                let out = URL(fileURLWithPath: args[1])
                let inputs = args.dropFirst(2).map { URL(fileURLWithPath: $0) }
                let elapsed = try await measureJoin(inputs: inputs, output: out)
                print(String(format: "JOIN_SECONDS=%.6f", elapsed))
            case "--validate":
                guard args.count >= 3 else { printUsage(); exit(2) }
                let out = URL(fileURLWithPath: args[1])
                let inputs = args.dropFirst(2).map { URL(fileURLWithPath: $0) }
                try await validate(output: out, inputs: inputs)
            case "--benchmark":
                guard args.count >= 3 else { printUsage(); exit(2) }
                let workDir = URL(fileURLWithPath: args[1], isDirectory: true)
                let inputs = args.dropFirst(2).map { URL(fileURLWithPath: $0) }
                try await runBenchmark(workDir: workDir, inputs: inputs)
            default:
                printUsage()
                exit(2)
            }
        } catch {
            fputs("Benchmark failed: \(error)\n", stderr)
            exit(1)
        }
    }

    static func printUsage() {
        fputs(
            """
            Usage:
              run_acceptance_benchmark --host-info
              run_acceptance_benchmark --copy <out.bin> <in1> [in2…]
              run_acceptance_benchmark --join <out.mov> <in1> [in2…]
              run_acceptance_benchmark --validate <out.mov> <in1> [in2…]
              run_acceptance_benchmark --benchmark <workDir> <in1> [in2…]

            """,
            stderr
        )
    }

    // MARK: - Host

    static func printHostInfo() {
        print("=== Host ===")
        print("model_id=\(sysctl("hw.model"))")
        print("cpu_brand=\(sysctl("machdep.cpu.brand_string"))")
        print("logical_cpus=\(sysctl("hw.logicalcpu"))")
        print("physical_cpus=\(sysctl("hw.physicalcpu"))")
        print("memsize_bytes=\(sysctl("hw.memsize"))")
        print("os_version=\(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("darwin=\(sysctl("kern.osproductversion")) (\(sysctl("kern.osversion")))")
    }

    static func sysctl(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: size)
        let status = sysctlbyname(name, &buffer, &size, nil, 0)
        guard status == 0, size > 0 else { return "unknown" }
        // Numeric sysctls arrive as raw bytes; detect common integer sizes.
        if size == MemoryLayout<Int32>.size {
            return buffer.withUnsafeBytes { "\($0.load(as: Int32.self))" }
        }
        if size == MemoryLayout<Int64>.size {
            return buffer.withUnsafeBytes { "\($0.load(as: Int64.self))" }
        }
        if size == MemoryLayout<UInt64>.size, name.contains("memsize") {
            return buffer.withUnsafeBytes { "\($0.load(as: UInt64.self))" }
        }
        return String(cString: buffer)
    }

    // MARK: - Copy / join

    static func measureCopy(of sources: [URL], to dest: URL) throws -> TimeInterval {
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let handle = try FileHandle(forWritingTo: dest)
        defer { try? handle.close() }

        let started = DispatchTime.now().uptimeNanoseconds
        for source in sources {
            let data = try Data(contentsOf: source, options: [.mappedIfSafe])
            try handle.write(contentsOf: data)
        }
        try handle.synchronize()
        return Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
    }

    static func measureJoin(inputs: [URL], output: URL) async throws -> TimeInterval {
        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }
        let started = DispatchTime.now().uptimeNanoseconds
        try await exportPassthrough(inputs: inputs, output: output)
        return Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
    }

    static func exportPassthrough(inputs: [URL], output: URL) async throws {
        let composition = AVMutableComposition()
        guard let videoComp = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw NSError(domain: "AcceptanceBenchmark", code: 1)
        }
        var audioComp: AVMutableCompositionTrack?
        var cursor = CMTime.zero

        for url in inputs {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            let range = CMTimeRange(start: .zero, duration: duration)
            let video = try await asset.loadTracks(withMediaType: .video)[0]
            try videoComp.insertTimeRange(range, of: video, at: cursor)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            if let audio = audioTracks.first {
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
            throw NSError(domain: "AcceptanceBenchmark", code: 2)
        }
        session.shouldOptimizeForNetworkUse = false

        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("movies-connector-accept-bench-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: temp) }
        try await session.export(to: temp, as: .mov)

        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: output.path) {
            _ = try FileManager.default.replaceItemAt(output, withItemAt: temp)
        } else {
            try FileManager.default.moveItem(at: temp, to: output)
        }
    }

    // MARK: - Validate

    static func validate(output: URL, inputs: [URL]) async throws {
        let outputAsset = AVURLAsset(url: output)
        let outputDuration = try await outputAsset.load(.duration)
        var sum = CMTime.zero
        var referenceCodec: String?
        var referenceWidth = 0
        var referenceHeight = 0

        for url in inputs {
            let asset = AVURLAsset(url: url)
            sum = CMTimeAdd(sum, try await asset.load(.duration))
            let video = try await asset.loadTracks(withMediaType: .video)[0]
            let formats = try await video.load(.formatDescriptions)
            let codec = fourCC(formats.first)
            let naturalSize = try await video.load(.naturalSize)
            let transform = try await video.load(.preferredTransform)
            let display = naturalSize.applying(transform)
            let width = Int(abs(display.width).rounded())
            let height = Int(abs(display.height).rounded())
            if referenceCodec == nil {
                referenceCodec = codec
                referenceWidth = width
                referenceHeight = height
            }
        }

        let outVideo = try await outputAsset.loadTracks(withMediaType: .video)[0]
        let outFormats = try await outVideo.load(.formatDescriptions)
        let outCodec = fourCC(outFormats.first)
        let outNatural = try await outVideo.load(.naturalSize)
        let outTransform = try await outVideo.load(.preferredTransform)
        let outDisplay = outNatural.applying(outTransform)
        let outWidth = Int(abs(outDisplay.width).rounded())
        let outHeight = Int(abs(outDisplay.height).rounded())

        let frameDuration = try await outVideo.load(.minFrameDuration)
        let frameSeconds = frameDuration.isValid && frameDuration.seconds > 0
            ? frameDuration.seconds
            : 1.0 / 30.0
        let delta = abs(outputDuration.seconds - sum.seconds)

        print("=== Validate ===")
        print("input_count=\(inputs.count)")
        print("sum_duration_s=\(sum.seconds)")
        print("output_duration_s=\(outputDuration.seconds)")
        print("duration_delta_s=\(delta)")
        print("one_frame_s=\(frameSeconds)")
        print("input_codec=\(referenceCodec ?? "nil")")
        print("output_codec=\(outCodec ?? "nil")")
        print("input_display=\(referenceWidth)x\(referenceHeight)")
        print("output_display=\(outWidth)x\(outHeight)")
        print("export_preset=AVAssetExportPresetPassthrough")

        guard outCodec == referenceCodec else {
            throw NSError(
                domain: "AcceptanceBenchmark",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "Codec mismatch (possible re-encode)"]
            )
        }
        guard outWidth == referenceWidth, outHeight == referenceHeight else {
            throw NSError(
                domain: "AcceptanceBenchmark",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "Display size mismatch"]
            )
        }
        guard delta <= frameSeconds + 0.000_5 else {
            throw NSError(
                domain: "AcceptanceBenchmark",
                code: 12,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Duration delta \(delta)s exceeds one frame \(frameSeconds)s",
                ]
            )
        }
        print("VALIDATE_OK=1")
    }

    // MARK: - Full benchmark (wall times; shell wraps joins with time -l for CPU)

    static func runBenchmark(workDir: URL, inputs: [URL]) async throws {
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        printHostInfo()

        var totalBytes: Int64 = 0
        print("=== Inputs ===")
        for url in inputs {
            let bytes = try fileSize(url)
            totalBytes += bytes
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            let video = try await asset.loadTracks(withMediaType: .video)[0]
            let formats = try await video.load(.formatDescriptions)
            let naturalSize = try await video.load(.naturalSize)
            let transform = try await video.load(.preferredTransform)
            let display = naturalSize.applying(transform)
            print(
                "\(url.lastPathComponent): bytes=\(bytes) duration_s=\(duration.seconds) codec=\(fourCC(formats.first) ?? "nil") size=\(Int(abs(display.width).rounded()))x\(Int(abs(display.height).rounded()))"
            )
        }
        print("total_source_bytes=\(totalBytes)")

        let sourceVolume = volumeDescription(for: inputs[0])
        let destVolume = volumeDescription(for: workDir)
        print("source_volume=\(sourceVolume)")
        print("dest_volume=\(destVolume)")

        let warmupJoin = workDir.appendingPathComponent("warmup-join.mov")
        let warmupCopy = workDir.appendingPathComponent("warmup-copy.bin")
        print("=== Warm-up ===")
        let wuCopy = try measureCopy(of: inputs, to: warmupCopy)
        let wuJoin = try await measureJoin(inputs: inputs, output: warmupJoin)
        print(String(format: "warmup_copy_s=%.6f", wuCopy))
        print(String(format: "warmup_join_s=%.6f", wuJoin))
        try await validate(output: warmupJoin, inputs: inputs)

        var copyTimes: [Double] = []
        var joinTimes: [Double] = []
        print("=== Measured trials (interleaved copy then join) ===")
        for trial in 1...5 {
            let copyURL = workDir.appendingPathComponent("trial-\(trial)-copy.bin")
            let joinURL = workDir.appendingPathComponent("trial-\(trial)-join.mov")
            let copyS = try measureCopy(of: inputs, to: copyURL)
            let joinS = try await measureJoin(inputs: inputs, output: joinURL)
            copyTimes.append(copyS)
            joinTimes.append(joinS)
            print(String(format: "trial=%d COPY_SECONDS=%.6f JOIN_SECONDS=%.6f", trial, copyS, joinS))
            try? FileManager.default.removeItem(at: copyURL)
            if trial < 5 {
                try? FileManager.default.removeItem(at: joinURL)
            }
        }

        let lastJoin = workDir.appendingPathComponent("trial-5-join.mov")
        try await validate(output: lastJoin, inputs: inputs)

        let medianCopy = median(copyTimes)
        let medianJoin = median(joinTimes)
        let ratio = medianCopy > 0 ? medianJoin / medianCopy : Double.nan
        print("=== Summary ===")
        print("copy_raw_s=\(copyTimes.map { String(format: "%.6f", $0) }.joined(separator: ","))")
        print("join_raw_s=\(joinTimes.map { String(format: "%.6f", $0) }.joined(separator: ","))")
        print(String(format: "median_copy_s=%.6f", medianCopy))
        print(String(format: "median_join_s=%.6f", medianJoin))
        print(String(format: "join_over_copy_ratio=%.3f", ratio))
        print(String(format: "kpi_1_25x_met=%@", ratio.isNaN ? "n/a" : (ratio <= 1.25 ? "yes" : "no")))
        print("note=CPU cores via /usr/bin/time -l are collected by Scripts/run_acceptance_benchmark.sh")
    }

    static func fileSize(_ url: URL) throws -> Int64 {
        Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }

    static func volumeDescription(for url: URL) -> String {
        if let values = try? url.resourceValues(forKeys: [.volumeNameKey, .volumeIsLocalKey]),
           let name = values.volumeName {
            let local = values.volumeIsLocal == true ? "local" : "non-local"
            return "\(name) (\(local))"
        }
        return url.path
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return .nan }
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
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
}

await AcceptanceBenchmark.run()
