import AVFoundation
import Foundation
import XCTest
@testable import MoviesConnector

/// Release-configuration speed harness that times the **production** `JoinExporter` path.
///
/// Opt-in only (`ACCEPTANCE_BENCHMARK=1`) so normal `xcodebuild test` stays fast/green.
/// Invoked by `Scripts/run_acceptance_benchmark.sh` with `-configuration Release` plus
/// harness overrides (`ENABLE_TESTABILITY=YES`, test-host signing relaxations) so the
/// Release `-O` `JoinExporter` module is testable and the XCTest host can load.
///
/// Environment:
///   ACCEPTANCE_BENCHMARK=1
///   ACCEPTANCE_FIXTURE_DIR=<dir with accept_*.mov>
///   ACCEPTANCE_WORK_DIR=<writable work dir>
final class AcceptanceProductionBenchmarkTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        JoinExporter.resetForTesting()
        AssetInspector.resetForTesting()
        installPermissiveAccessMocks()
    }

    override func tearDown() {
        JoinExporter.resetForTesting()
        AssetInspector.resetForTesting()
        UserSelectedURLAccess.resetForTesting()
        super.tearDown()
    }

    func testProductionJoinExporterAcceptanceBenchmark() async throws {
        guard ProcessInfo.processInfo.environment["ACCEPTANCE_BENCHMARK"] == "1" else {
            throw XCTSkip("Set ACCEPTANCE_BENCHMARK=1 to run the production Release join harness")
        }

        let fixtureDir = requiredEnvURL("ACCEPTANCE_FIXTURE_DIR", isDirectory: true)
        let workDir = requiredEnvURL("ACCEPTANCE_WORK_DIR", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let inputs = try sortedAcceptanceInputs(in: fixtureDir)
        XCTAssertGreaterThanOrEqual(inputs.count, 2, "Need ≥2 accept_*.mov in \(fixtureDir.path)")

        var lines: [String] = []
        func emit(_ line: String) {
            print(line)
            lines.append(line)
        }

        emit("# Movies Connector acceptance benchmark (production JoinExporter, Release)")
        emit("date=\(ISO8601DateFormatter().string(from: Date()))")
        emit("engine=JoinExporter.join")
        emit("build_configuration=Release (required via Scripts/run_acceptance_benchmark.sh)")
        emit("fixture_dir=\(fixtureDir.path)")
        emit("work_dir=\(workDir.path)")
        emit("export_preset=AVAssetExportPresetPassthrough")
        emit("")

        emitHostInfo(emit)
        emit("")

        var totalBytes: Int64 = 0
        var inputSignatures: [CompatibilitySignature] = []
        emit("=== Inputs ===")
        for url in inputs {
            let bytes = try fileSize(url)
            totalBytes += bytes
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            let signature = try await AssetInspector.makeSignature(for: url)
            inputSignatures.append(signature)
            emit(
                "\(url.lastPathComponent): bytes=\(bytes) duration_s=\(duration.seconds) " +
                    "codec=\(signature.videoCodec ?? "nil") " +
                    "size=\(signature.videoDisplayWidth)x\(signature.videoDisplayHeight) " +
                    "audio=\(signature.audioCodec ?? "nil") " +
                    "tracks=v\(signature.videoTrackCount)/a\(signature.audioTrackCount)"
            )
        }
        emit("total_source_bytes=\(totalBytes)")
        emit("input_count=\(inputs.count)")

        let sourceVolume = volumeDescription(for: inputs[0])
        let destVolume = volumeDescription(for: workDir)
        emit("source_volume=\(sourceVolume)")
        emit("dest_volume=\(destVolume)")

        // All inputs must be mutually compatible (full CompatibilitySignature).
        let reference = inputSignatures[0]
        for (index, signature) in inputSignatures.enumerated().dropFirst() {
            let mismatches = CompatibilityComparer.mismatches(between: reference, and: signature)
            XCTAssertTrue(
                mismatches.isEmpty,
                "Input[\(index)] incompatible with input[0]: \(mismatches.map(\.description).joined(separator: "; "))"
            )
        }

        let eligibility = TargetWorkloadEligibility.evaluate(
            inputCount: inputs.count,
            signatures: inputSignatures,
            totalSourceBytes: totalBytes,
            sourceIsLocal: volumeIsLocal(inputs[0]),
            destIsLocal: volumeIsLocal(workDir),
            isAppleSilicon: isAppleSilicon()
        )
        emit("")
        emit("=== Target eligibility (DESIGN.md 4K×10≈20GB KPI) ===")
        for reason in eligibility.reasons {
            emit("eligibility_reason=\(reason)")
        }
        emit("workload_class=\(eligibility.workloadClass)")
        emit("target_eligible=\(eligibility.isEligible ? "yes" : "no")")

        let wallDir = workDir.appendingPathComponent("wall", isDirectory: true)
        try FileManager.default.createDirectory(at: wallDir, withIntermediateDirectories: true)

        emit("")
        emit("=== Warm-up ===")
        let warmupCopy = wallDir.appendingPathComponent("warmup-copy.bin")
        let warmupJoin = wallDir.appendingPathComponent("warmup-join.mov")
        let wuCopy = try measureCopy(of: inputs, to: warmupCopy)
        let wuJoin = try await measureProductionJoin(inputs: inputs, output: warmupJoin)
        emit(String(format: "warmup_copy_s=%.6f", wuCopy))
        emit(String(format: "warmup_join_s=%.6f", wuJoin.seconds))
        try await validateOutput(output: warmupJoin, inputs: inputs, reference: reference, emit: emit)

        var copyTimes: [Double] = []
        var joinTimes: [Double] = []
        var cpuSamples: [Double] = []

        emit("")
        emit("=== Measured trials (interleaved copy then JoinExporter.join) ===")
        for trial in 1...5 {
            let copyURL = wallDir.appendingPathComponent("trial-\(trial)-copy.bin")
            let joinURL = wallDir.appendingPathComponent("trial-\(trial)-join.mov")
            let copyS = try measureCopy(of: inputs, to: copyURL)
            let join = try await measureProductionJoin(inputs: inputs, output: joinURL)
            copyTimes.append(copyS)
            joinTimes.append(join.seconds)
            cpuSamples.append(join.avgCores)
            emit(
                String(
                    format: "trial=%d COPY_SECONDS=%.6f JOIN_SECONDS=%.6f AVG_CORES=%.3f",
                    trial,
                    copyS,
                    join.seconds,
                    join.avgCores
                )
            )
            try? FileManager.default.removeItem(at: copyURL)
            if trial < 5 {
                try? FileManager.default.removeItem(at: joinURL)
            }
        }

        let lastJoin = wallDir.appendingPathComponent("trial-5-join.mov")
        try await validateOutput(output: lastJoin, inputs: inputs, reference: reference, emit: emit)

        let medianCopy = median(copyTimes)
        let medianJoin = median(joinTimes)
        let ratio = medianCopy > 0 ? medianJoin / medianCopy : Double.nan
        let meanCores = cpuSamples.reduce(0, +) / Double(cpuSamples.count)

        emit("")
        emit("=== Summary ===")
        emit("copy_raw_s=\(copyTimes.map { String(format: "%.6f", $0) }.joined(separator: ","))")
        emit("join_raw_s=\(joinTimes.map { String(format: "%.6f", $0) }.joined(separator: ","))")
        emit("avg_cores_raw=\(cpuSamples.map { String(format: "%.3f", $0) }.joined(separator: ","))")
        emit(String(format: "median_copy_s=%.6f", medianCopy))
        emit(String(format: "median_join_s=%.6f", medianJoin))
        emit(String(format: "join_over_copy_ratio=%.3f", ratio))
        emit(String(format: "mean_avg_cores_over_trials=%.3f", meanCores))
        emit("cpu_method=getrusage(RUSAGE_SELF) around JoinExporter.join; avg_cores=(user+sys)/wall")

        if eligibility.isEligible {
            emit(String(format: "kpi_1_25x_met=%@", ratio.isNaN ? "n/a" : (ratio <= 1.25 ? "yes" : "no")))
            emit(String(format: "cpu_under_1_core=%@", meanCores < 1.0 ? "yes" : "no"))
        } else {
            emit("kpi_1_25x_met=n/a")
            emit("cpu_under_1_core=n/a")
            emit("kpi_status=surrogate_only")
            emit(
                "note=Surrogate/out-of-target workload — DESIGN.md 1.25× / <1-core KPIs are not scored. " +
                    "Do not treat these numbers as a 20GB 4K KPI pass/fail."
            )
        }

        let resultsURL = workDir.appendingPathComponent("results.txt")
        try lines.joined(separator: "\n").appending("\n").write(to: resultsURL, atomically: true, encoding: .utf8)
        emit("results_path=\(resultsURL.path)")
    }

    /// Always-on: production join output must match every input's format description / topology.
    func testValidateComparesAllInputAndOutputFormatDescriptions() async throws {
        let a = try await TestMovieFixtures.url(named: "compat_a.mov")
        let b = try await TestMovieFixtures.url(named: "compat_b.mov")
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("accept-fmt-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: output) }

        let reference = try await AssetInspector.makeSignature(for: a)
        let sigB = try await AssetInspector.makeSignature(for: b)
        XCTAssertTrue(CompatibilityComparer.mismatches(between: reference, and: sigB).isEmpty)

        _ = try await JoinExporter.join(inputURLs: [a, b], outputURL: output)
        try await validateOutput(output: output, inputs: [a, b], reference: reference, emit: { _ in })
    }

    /// Always-on unit coverage for eligibility gating (prevents surrogate false positives).
    func testTargetEligibilityRejects720pSurrogateAndKpi20PresetShape() {
        let surrogate720 = CompatibilitySignature(
            videoTrackCount: 1,
            audioTrackCount: 1,
            hasUnsupportedTracks: false,
            videoCodec: "avc1",
            videoDisplayWidth: 1280,
            videoDisplayHeight: 720,
            videoPreferredTransform: .identity,
            videoFrameDuration: .init(value: 1, timescale: 30),
            videoTimescale: 30,
            audioCodec: "aac",
            audioSampleRate: 48_000,
            audioChannelCount: 2,
            audioFormatFlags: nil
        )
        let signatures = Array(repeating: surrogate720, count: 10)
        // ~1.22 GB practical set
        let practical = TargetWorkloadEligibility.evaluate(
            inputCount: 10,
            signatures: signatures,
            totalSourceBytes: 1_223_641_170,
            sourceIsLocal: true,
            destIsLocal: true,
            isAppleSilicon: true
        )
        XCTAssertFalse(practical.isEligible)
        XCTAssertEqual(practical.workloadClass, "surrogate_only")
        XCTAssertTrue(practical.reasons.contains(where: { $0.contains("4K") }))

        // kpi20 preset is ~20 GB but still 720p — must NOT be target-eligible.
        let kpi20Shape = TargetWorkloadEligibility.evaluate(
            inputCount: 10,
            signatures: signatures,
            totalSourceBytes: 20_000_000_000,
            sourceIsLocal: true,
            destIsLocal: true,
            isAppleSilicon: true
        )
        XCTAssertFalse(kpi20Shape.isEligible)
        XCTAssertEqual(kpi20Shape.workloadClass, "surrogate_only")
        XCTAssertTrue(kpi20Shape.reasons.contains(where: { $0.contains("4K") }))

        let fourK = CompatibilitySignature(
            videoTrackCount: 1,
            audioTrackCount: 1,
            hasUnsupportedTracks: false,
            videoCodec: "hvc1",
            videoDisplayWidth: 3840,
            videoDisplayHeight: 2160,
            videoPreferredTransform: .identity,
            videoFrameDuration: .init(value: 1, timescale: 30),
            videoTimescale: 30,
            audioCodec: "aac",
            audioSampleRate: 48_000,
            audioChannelCount: 2,
            audioFormatFlags: nil
        )
        let target = TargetWorkloadEligibility.evaluate(
            inputCount: 10,
            signatures: Array(repeating: fourK, count: 10),
            totalSourceBytes: 20_000_000_000,
            sourceIsLocal: true,
            destIsLocal: true,
            isAppleSilicon: true
        )
        XCTAssertTrue(target.isEligible)
        XCTAssertEqual(target.workloadClass, "target_kpi")
    }

    // MARK: - Production join + copy

    private struct JoinMeasurement {
        var seconds: Double
        var avgCores: Double
    }

    private func measureProductionJoin(inputs: [URL], output: URL) async throws -> JoinMeasurement {
        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }
        let usageBefore = processUsage()
        let wallStarted = DispatchTime.now().uptimeNanoseconds
        _ = try await JoinExporter.join(inputURLs: inputs, outputURL: output)
        let wallSeconds = Double(DispatchTime.now().uptimeNanoseconds - wallStarted) / 1_000_000_000
        let usageAfter = processUsage()
        let cpuSeconds = max(0, (usageAfter.user + usageAfter.system) - (usageBefore.user + usageBefore.system))
        let avgCores = wallSeconds > 0 ? cpuSeconds / wallSeconds : Double.nan
        return JoinMeasurement(seconds: wallSeconds, avgCores: avgCores)
    }

    private func measureCopy(of sources: [URL], to dest: URL) throws -> TimeInterval {
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

    // MARK: - Validation (all inputs + output format descriptions / topology)

    private func validateOutput(
        output: URL,
        inputs: [URL],
        reference: CompatibilitySignature,
        emit: (String) -> Void
    ) async throws {
        let outputAsset = AVURLAsset(url: output)
        let outputDuration = try await outputAsset.load(.duration)
        var sum = CMTime.zero
        for url in inputs {
            sum = CMTimeAdd(sum, try await AVURLAsset(url: url).load(.duration))
        }

        let outputSignature = try await AssetInspector.makeSignature(for: output)
        let mismatches = CompatibilityComparer.mismatches(between: reference, and: outputSignature)
        emit("=== Validate (CompatibilitySignature, all inputs → output) ===")
        emit("input_count=\(inputs.count)")
        emit("sum_duration_s=\(sum.seconds)")
        emit("output_duration_s=\(outputDuration.seconds)")
        emit(
            "output_signature=codec=\(outputSignature.videoCodec ?? "nil") " +
                "size=\(outputSignature.videoDisplayWidth)x\(outputSignature.videoDisplayHeight) " +
                "audio=\(outputSignature.audioCodec ?? "nil") " +
                "tracks=v\(outputSignature.videoTrackCount)/a\(outputSignature.audioTrackCount) " +
                "unsupported=\(outputSignature.hasUnsupportedTracks)"
        )
        emit("export_preset=AVAssetExportPresetPassthrough")

        XCTAssertTrue(
            mismatches.isEmpty,
            "Output format/topology mismatch vs inputs: \(mismatches.map(\.description).joined(separator: "; "))"
        )

        // Explicit format-description FourCC check on every input + output video/audio track.
        for (index, url) in inputs.enumerated() {
            try await assertFormatDescriptionsMatchReference(
                url: url,
                reference: reference,
                label: "input[\(index)]"
            )
        }
        try await assertFormatDescriptionsMatchReference(
            url: output,
            reference: reference,
            label: "output"
        )

        let frameSeconds: Double
        if let rational = reference.videoFrameDuration, rational.timescale > 0 {
            frameSeconds = Double(rational.value) / Double(rational.timescale)
        } else {
            frameSeconds = 1.0 / 30.0
        }
        let delta = abs(outputDuration.seconds - sum.seconds)
        emit("duration_delta_s=\(delta)")
        emit("one_frame_s=\(frameSeconds)")
        XCTAssertLessThanOrEqual(
            delta,
            frameSeconds + 0.000_5,
            "Duration delta \(delta)s exceeds one frame \(frameSeconds)s"
        )
        emit("VALIDATE_OK=1")
    }

    private func assertFormatDescriptionsMatchReference(
        url: URL,
        reference: CompatibilitySignature,
        label: String
    ) async throws {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.load(.tracks)
        let videoTracks = tracks.filter { $0.mediaType == .video }
        let audioTracks = tracks.filter { $0.mediaType == .audio }
        let otherTracks = tracks.filter { $0.mediaType != .video && $0.mediaType != .audio }

        XCTAssertEqual(videoTracks.count, reference.videoTrackCount, "\(label) video track count")
        XCTAssertEqual(audioTracks.count, reference.audioTrackCount, "\(label) audio track count")
        XCTAssertEqual(otherTracks.isEmpty, !reference.hasUnsupportedTracks, "\(label) unsupported tracks")

        let video = try XCTUnwrap(videoTracks.first, "\(label) missing video")
        let videoFormats = try await video.load(.formatDescriptions)
        XCTAssertFalse(videoFormats.isEmpty, "\(label) missing video format description")
        XCTAssertEqual(fourCC(videoFormats.first), reference.videoCodec, "\(label) video FourCC")

        let naturalSize = try await video.load(.naturalSize)
        let transform = try await video.load(.preferredTransform)
        let display = naturalSize.applying(transform)
        XCTAssertEqual(Int(abs(display.width).rounded()), reference.videoDisplayWidth, "\(label) width")
        XCTAssertEqual(Int(abs(display.height).rounded()), reference.videoDisplayHeight, "\(label) height")

        if reference.audioTrackCount > 0 {
            let audio = try XCTUnwrap(audioTracks.first, "\(label) missing audio")
            let audioFormats = try await audio.load(.formatDescriptions)
            XCTAssertFalse(audioFormats.isEmpty, "\(label) missing audio format description")
            XCTAssertEqual(fourCC(audioFormats.first), reference.audioCodec, "\(label) audio FourCC")
        }
    }

    // MARK: - Host / eligibility helpers

    private func emitHostInfo(_ emit: (String) -> Void) {
        emit("=== Host ===")
        emit("model_id=\(sysctl("hw.model"))")
        emit("cpu_brand=\(sysctl("machdep.cpu.brand_string"))")
        emit("logical_cpus=\(sysctl("hw.logicalcpu"))")
        emit("physical_cpus=\(sysctl("hw.physicalcpu"))")
        emit("memsize_bytes=\(sysctl("hw.memsize"))")
        emit("os_version=\(ProcessInfo.processInfo.operatingSystemVersionString)")
        emit("darwin=\(sysctl("kern.osproductversion")) (\(sysctl("kern.osversion")))")
        emit("apple_silicon=\(isAppleSilicon() ? "yes" : "no")")
    }

    private func requiredEnvURL(_ key: String, isDirectory: Bool) -> URL {
        guard let value = ProcessInfo.processInfo.environment[key], !value.isEmpty else {
            XCTFail("Missing required environment variable \(key)")
            return URL(fileURLWithPath: "/tmp")
        }
        return URL(fileURLWithPath: value, isDirectory: isDirectory)
    }

    private func sortedAcceptanceInputs(in directory: URL) throws -> [URL] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        return contents
            .filter { $0.lastPathComponent.hasPrefix("accept_") && $0.pathExtension.lowercased() == "mov" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func installPermissiveAccessMocks() {
        // Harness exercises the production JoinExporter engine on local fixture paths
        // (open-panel security-scope is covered separately by FileAccess tests / manual iCloud).
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

    private func fileSize(_ url: URL) throws -> Int64 {
        Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }

    private func volumeDescription(for url: URL) -> String {
        if let values = try? url.resourceValues(forKeys: [.volumeNameKey, .volumeIsLocalKey]),
           let name = values.volumeName
        {
            let local = values.volumeIsLocal == true ? "local" : "non-local"
            return "\(name) (\(local))"
        }
        return url.path
    }

    private func volumeIsLocal(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == true
    }

    private func isAppleSilicon() -> Bool {
        var size = MemoryLayout<Int32>.size
        var value: Int32 = 0
        let status = sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
        return status == 0 && value == 1
    }

    private func sysctl(_ name: String) -> String {
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

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return .nan }
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
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

    private struct ProcessUsage {
        var user: Double
        var system: Double
    }

    private func processUsage() -> ProcessUsage {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return ProcessUsage(user: user, system: system)
    }
}

/// Explicit DESIGN.md target-workload gate. Surrogates (incl. `kpi20` 720p seed repeats) never score KPIs.
enum TargetWorkloadEligibility {
    struct Result: Equatable {
        var isEligible: Bool
        var workloadClass: String
        var reasons: [String]
    }

    /// ~20 GB with ±10% tolerance (18…22 decimal GB).
    static let minTargetBytes: Int64 = 18_000_000_000
    static let maxTargetBytes: Int64 = 22_000_000_000

    static func evaluate(
        inputCount: Int,
        signatures: [CompatibilitySignature],
        totalSourceBytes: Int64,
        sourceIsLocal: Bool,
        destIsLocal: Bool,
        isAppleSilicon: Bool
    ) -> Result {
        var reasons: [String] = []

        if inputCount != 10 {
            reasons.append("input_count=\(inputCount) (need 10)")
        }
        if signatures.count != inputCount {
            reasons.append("signature_count=\(signatures.count) mismatches input_count=\(inputCount)")
        }

        let all4K = signatures.allSatisfy { is4KDisplay(width: $0.videoDisplayWidth, height: $0.videoDisplayHeight) }
        if !all4K {
            let sample = signatures.first.map { "\($0.videoDisplayWidth)x\($0.videoDisplayHeight)" } ?? "unknown"
            reasons.append("not_4K (sample display \(sample); need ≥3840×2160 or 2160×3840 on every clip)")
        }

        if totalSourceBytes < minTargetBytes || totalSourceBytes > maxTargetBytes {
            reasons.append(
                "total_bytes=\(totalSourceBytes) outside ≈20GB window [\(minTargetBytes)…\(maxTargetBytes)]"
            )
        }
        if !isAppleSilicon {
            reasons.append("host is not Apple Silicon")
        }
        if !sourceIsLocal {
            reasons.append("source volume is not local")
        }
        if !destIsLocal {
            reasons.append("destination volume is not local")
        }

        if reasons.isEmpty {
            return Result(isEligible: true, workloadClass: "target_kpi", reasons: ["all target checks passed"])
        }
        return Result(isEligible: false, workloadClass: "surrogate_only", reasons: reasons)
    }

    static func is4KDisplay(width: Int, height: Int) -> Bool {
        (width >= 3840 && height >= 2160) || (width >= 2160 && height >= 3840)
    }
}
