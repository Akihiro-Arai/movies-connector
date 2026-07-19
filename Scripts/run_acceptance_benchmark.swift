#!/usr/bin/env swift
import AVFoundation
import Foundation

/// Support utilities for acceptance docs (AVFoundation only — no FFmpeg).
///
/// **KPI joins are NOT measured here.** Use `Scripts/run_acceptance_benchmark.sh`, which runs
/// `AcceptanceProductionBenchmarkTests` against Release `JoinExporter.join`.
///
/// Modes:
///   --host-info
///   --copy <out.bin> <in1> [in2…]
///   --validate <out.mov> <in1> [in2…]
///   --eligibility <in1> [in2…] [ --dest <workDir> ]

enum AcceptanceBenchmarkSupport {
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
            case "--validate":
                guard args.count >= 3 else { printUsage(); exit(2) }
                let out = URL(fileURLWithPath: args[1])
                let inputs = args.dropFirst(2).map { URL(fileURLWithPath: $0) }
                try await validate(output: out, inputs: inputs)
            case "--eligibility":
                guard args.count >= 2 else { printUsage(); exit(2) }
                var dest: URL?
                var inputs: [URL] = []
                var i = 1
                while i < args.count {
                    if args[i] == "--dest", i + 1 < args.count {
                        dest = URL(fileURLWithPath: args[i + 1], isDirectory: true)
                        i += 2
                        continue
                    }
                    inputs.append(URL(fileURLWithPath: args[i]))
                    i += 1
                }
                try await printEligibility(inputs: inputs, dest: dest ?? inputs[0].deletingLastPathComponent())
            case "--join", "--benchmark":
                fputs(
                    """
                    ERROR: --join/--benchmark were removed from this script.
                    KPI timing must use the production Release JoinExporter via:
                      Scripts/run_acceptance_benchmark.sh [fixtureDir] [workDir]

                    """,
                    stderr
                )
                exit(2)
            default:
                printUsage()
                exit(2)
            }
        } catch {
            fputs("Benchmark support failed: \(error)\n", stderr)
            exit(1)
        }
    }

    static func printUsage() {
        fputs(
            """
            Usage (support utilities only — KPI joins use run_acceptance_benchmark.sh):
              run_acceptance_benchmark --host-info
              run_acceptance_benchmark --copy <out.bin> <in1> [in2…]
              run_acceptance_benchmark --validate <out.mov> <in1> [in2…]
              run_acceptance_benchmark --eligibility <in1> [in2…] [--dest <workDir>]

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
        print("apple_silicon=\(isAppleSilicon() ? "yes" : "no")")
    }

    static func sysctl(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: size)
        let status = sysctlbyname(name, &buffer, &size, nil, 0)
        guard status == 0, size > 0 else { return "unknown" }
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

    static func isAppleSilicon() -> Bool {
        var size = MemoryLayout<Int32>.size
        var value: Int32 = 0
        let status = sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
        return status == 0 && value == 1
    }

    // MARK: - Copy

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

    // MARK: - Eligibility

    static func printEligibility(inputs: [URL], dest: URL) async throws {
        var totalBytes: Int64 = 0
        var displays: [(Int, Int)] = []
        for url in inputs {
            totalBytes += try fileSize(url)
            let asset = AVURLAsset(url: url)
            let video = try await asset.loadTracks(withMediaType: .video)[0]
            let naturalSize = try await video.load(.naturalSize)
            let transform = try await video.load(.preferredTransform)
            let display = naturalSize.applying(transform)
            displays.append((Int(abs(display.width).rounded()), Int(abs(display.height).rounded())))
        }

        let all4K = displays.allSatisfy { is4K(width: $0.0, height: $0.1) }
        let sourceLocal = volumeIsLocal(inputs[0])
        let destLocal = volumeIsLocal(dest)
        let apple = isAppleSilicon()
        let bytesOK = totalBytes >= 18_000_000_000 && totalBytes <= 22_000_000_000
        let countOK = inputs.count == 10
        let eligible = countOK && all4K && bytesOK && apple && sourceLocal && destLocal

        print("=== Target eligibility ===")
        print("input_count=\(inputs.count) (need 10) → \(countOK ? "ok" : "fail")")
        print("all_4k=\(all4K ? "yes" : "no") sample=\(displays.first.map { "\($0.0)x\($0.1)" } ?? "n/a")")
        print("total_source_bytes=\(totalBytes) (need 18e9…22e9) → \(bytesOK ? "ok" : "fail")")
        print("apple_silicon=\(apple ? "yes" : "no")")
        print("source_local=\(sourceLocal ? "yes" : "no")")
        print("dest_local=\(destLocal ? "yes" : "no")")
        print("target_eligible=\(eligible ? "yes" : "no")")
        print("workload_class=\(eligible ? "target_kpi" : "surrogate_only")")
        if !eligible {
            print("kpi_1_25x_met=n/a")
            print("cpu_under_1_core=n/a")
            print("note=Out-of-target / surrogate — do not score DESIGN.md 20GB KPIs.")
        }
    }

    static func is4K(width: Int, height: Int) -> Bool {
        (width >= 3840 && height >= 2160) || (width >= 2160 && height >= 3840)
    }

    // MARK: - Validate (all inputs + output format descriptions / topology)

    static func validate(output: URL, inputs: [URL]) async throws {
        struct Sig: Equatable {
            var videoTrackCount: Int
            var audioTrackCount: Int
            var hasUnsupportedTracks: Bool
            var videoCodec: String?
            var videoWidth: Int
            var videoHeight: Int
            var videoTransform: String
            var videoFrameDuration: String?
            var videoTimescale: Int32?
            var audioCodec: String?
            var audioSampleRate: Double?
            var audioChannelCount: Int?
            var audioFormatFlags: UInt32?
        }

        func loadSig(_ url: URL) async throws -> (CMTime, Sig) {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            let tracks = try await asset.load(.tracks)
            let videoTracks = tracks.filter { $0.mediaType == .video }
            let audioTracks = tracks.filter { $0.mediaType == .audio }
            let other = tracks.filter { $0.mediaType != .video && $0.mediaType != .audio }
            guard let video = videoTracks.first else {
                throw NSError(domain: "AcceptanceBenchmark", code: 20, userInfo: [
                    NSLocalizedDescriptionKey: "Missing video track: \(url.lastPathComponent)",
                ])
            }
            let formats = try await video.load(.formatDescriptions)
            let naturalSize = try await video.load(.naturalSize)
            let transform = try await video.load(.preferredTransform)
            let display = naturalSize.applying(transform)
            let minFrame = try await video.load(.minFrameDuration)
            let timescale = try await video.load(.naturalTimeScale)

            var audioCodec: String?
            var sampleRate: Double?
            var channels: Int?
            var flags: UInt32?
            if let audio = audioTracks.first {
                let audioFormats = try await audio.load(.formatDescriptions)
                audioCodec = fourCC(audioFormats.first)
                if let description = audioFormats.first,
                   let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
                {
                    sampleRate = asbd.mSampleRate
                    channels = Int(asbd.mChannelsPerFrame)
                    flags = asbd.mFormatFlags
                }
            }

            let frameKey: String?
            if minFrame.isValid && !minFrame.isIndefinite && minFrame.value > 0 {
                frameKey = "\(minFrame.value)/\(minFrame.timescale)"
            } else {
                frameKey = nil
            }

            let sig = Sig(
                videoTrackCount: videoTracks.count,
                audioTrackCount: audioTracks.count,
                hasUnsupportedTracks: !other.isEmpty,
                videoCodec: fourCC(formats.first),
                videoWidth: Int(abs(display.width).rounded()),
                videoHeight: Int(abs(display.height).rounded()),
                videoTransform: "\(transform.a),\(transform.b),\(transform.c),\(transform.d),\(transform.tx),\(transform.ty)",
                videoFrameDuration: frameKey,
                videoTimescale: timescale == 0 ? nil : timescale,
                audioCodec: audioCodec,
                audioSampleRate: sampleRate,
                audioChannelCount: channels,
                audioFormatFlags: flags
            )
            return (duration, sig)
        }

        var sum = CMTime.zero
        var reference: Sig?
        print("=== Validate (all inputs + output format descriptions) ===")
        for (index, url) in inputs.enumerated() {
            let (duration, sig) = try await loadSig(url)
            sum = CMTimeAdd(sum, duration)
            print(
                "input[\(index)]=\(url.lastPathComponent) codec=\(sig.videoCodec ?? "nil") " +
                    "size=\(sig.videoWidth)x\(sig.videoHeight) audio=\(sig.audioCodec ?? "nil") " +
                    "tracks=v\(sig.videoTrackCount)/a\(sig.audioTrackCount)"
            )
            if let reference {
                guard sig == reference else {
                    throw NSError(domain: "AcceptanceBenchmark", code: 21, userInfo: [
                        NSLocalizedDescriptionKey: "Input[\(index)] format/topology mismatch vs input[0]",
                    ])
                }
            } else {
                reference = sig
            }
        }

        let (outputDuration, outSig) = try await loadSig(output)
        guard let reference else {
            throw NSError(domain: "AcceptanceBenchmark", code: 22, userInfo: [
                NSLocalizedDescriptionKey: "No inputs",
            ])
        }
        print(
            "output codec=\(outSig.videoCodec ?? "nil") size=\(outSig.videoWidth)x\(outSig.videoHeight) " +
                "audio=\(outSig.audioCodec ?? "nil") tracks=v\(outSig.videoTrackCount)/a\(outSig.audioTrackCount)"
        )
        guard outSig == reference else {
            throw NSError(domain: "AcceptanceBenchmark", code: 23, userInfo: [
                NSLocalizedDescriptionKey: "Output format/topology mismatch vs inputs",
            ])
        }

        let frameSeconds: Double
        if let key = reference.videoFrameDuration,
           let valuePart = key.split(separator: "/").first,
           let scalePart = key.split(separator: "/").last,
           let value = Double(valuePart),
           let scale = Double(scalePart),
           scale > 0
        {
            frameSeconds = value / scale
        } else {
            frameSeconds = 1.0 / 30.0
        }
        let delta = abs(outputDuration.seconds - sum.seconds)
        print("input_count=\(inputs.count)")
        print("sum_duration_s=\(sum.seconds)")
        print("output_duration_s=\(outputDuration.seconds)")
        print("duration_delta_s=\(delta)")
        print("one_frame_s=\(frameSeconds)")
        print("export_preset=AVAssetExportPresetPassthrough")
        guard delta <= frameSeconds + 0.000_5 else {
            throw NSError(domain: "AcceptanceBenchmark", code: 12, userInfo: [
                NSLocalizedDescriptionKey: "Duration delta \(delta)s exceeds one frame \(frameSeconds)s",
            ])
        }
        print("VALIDATE_OK=1")
    }

    static func fileSize(_ url: URL) throws -> Int64 {
        Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }

    static func volumeIsLocal(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == true
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

await AcceptanceBenchmarkSupport.run()
