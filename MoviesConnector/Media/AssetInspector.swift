import AVFoundation
import CoreMedia
import Foundation

enum AssetInspectorError: Error, LocalizedError, Equatable {
    case noVideoTrack
    case unreadable(String)
    case incompatible([String])

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "Asset has no video track"
        case .unreadable(let detail):
            return "Asset is unreadable: \(detail)"
        case .incompatible(let reasons):
            return "Inputs are incompatible for passthrough: \(reasons.joined(separator: "; "))"
        }
    }
}

/// Per-row status after inspection and (for batch preflight) reference comparison.
enum AssetRowStatus: Sendable, Equatable {
    case compatible
    case unreadable(String)
    case unsupported(String)
    case mismatch([CompatibilityMismatch])

    var isAcceptable: Bool {
        if case .compatible = self { return true }
        return false
    }

    /// Human-readable reasons for this row (empty when compatible).
    var reasons: [String] {
        switch self {
        case .compatible:
            return []
        case .unreadable(let detail):
            return [detail]
        case .unsupported(let detail):
            return [detail]
        case .mismatch(let mismatches):
            return mismatches.map(\.description)
        }
    }
}

/// Typed inspection result for one input URL (UI row or exporter preflight entry).
struct AssetInspectionResult: Sendable, Equatable {
    var url: URL
    /// Zero-based index in the caller's ordered input list.
    var index: Int
    /// Asset duration when readable; nil when duration could not be loaded.
    var duration: CMTime?
    /// Compatibility fingerprint when metadata was readable enough to build one.
    var signature: CompatibilitySignature?
    var status: AssetRowStatus
}

/// Batch preflight report preserving caller order. First item is the reference.
struct PreflightReport: Sendable, Equatable {
    var results: [AssetInspectionResult]

    var canExport: Bool {
        !results.isEmpty && results.allSatisfy(\.status.isAcceptable)
    }

    /// Row-addressable failure reasons for UI / exporter error messages.
    var rowReasons: [(index: Int, reasons: [String])] {
        results.compactMap { result in
            let reasons = result.status.reasons
            guard !reasons.isEmpty else { return nil }
            return (result.index, reasons)
        }
    }

    /// Flattened `file[i]: …` strings (exporter-friendly).
    var formattedReasons: [String] {
        rowReasons.flatMap { row in
            row.reasons.map { "file[\(row.index)]: \($0)" }
        }
    }
}

/// Loads local (and downloaded iCloud) media metadata asynchronously for compatibility checks.
///
/// All entry points are nonisolated async APIs that use `AVURLAsset` property loading and must not
/// be treated as main-actor work — callers on `@MainActor` should `await` these methods so the
/// actor can suspend while I/O and track inspection run.
enum AssetInspector: Sendable {
    /// Inspect a single asset: duration + signature when readable, with intrinsic topology status.
    /// Does not compare against peers; use `preflight(urls:)` for ordered set evaluation.
    nonisolated static func inspect(_ url: URL, index: Int = 0) async -> AssetInspectionResult {
        await loadInspection(url: url, index: index)
    }

    /// Batch preflight for an ordered input set. The first URL is the reference
    /// (`docs/COMPATIBILITY.md`). Re-call whenever items are added, removed, or reordered.
    /// Preserves the caller's input order in `PreflightReport.results`.
    nonisolated static func preflight(urls: [URL]) async -> PreflightReport {
        var loaded: [AssetInspectionResult] = []
        loaded.reserveCapacity(urls.count)
        for (index, url) in urls.enumerated() {
            loaded.append(await loadInspection(url: url, index: index))
        }
        return evaluate(loadedInspections: loaded)
    }

    /// Recompute compatibility after reorder / reference change without reloading AVAssets.
    ///
    /// Pass previously loaded inspections in the new order (URLs + signatures + durations).
    /// Indices in the returned report are rewritten to match the new order.
    nonisolated static func preflight(reusing inspections: [AssetInspectionResult]) -> PreflightReport {
        let reindexed = inspections.enumerated().map { index, item in
            AssetInspectionResult(
                url: item.url,
                index: index,
                duration: item.duration,
                signature: item.signature,
                status: item.status
            )
        }
        return evaluate(loadedInspections: reindexed)
    }

    /// Exporter-callable immediate preflight: throws when the ordered set cannot passthrough-join.
    nonisolated static func assertCompatibleForExport(urls: [URL]) async throws {
        let report = await preflight(urls: urls)
        guard report.canExport else {
            throw AssetInspectorError.incompatible(report.formattedReasons)
        }
    }

    /// Loads track metadata and builds a `CompatibilitySignature` for rejection checks on add.
    nonisolated static func makeSignature(for url: URL) async throws -> CompatibilitySignature {
        let asset = AVURLAsset(url: url)
        return try await makeSignature(for: asset)
    }

    nonisolated static func makeSignature(for asset: AVAsset) async throws -> CompatibilitySignature {
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.load(.tracks)
        } catch {
            throw AssetInspectorError.unreadable(error.localizedDescription)
        }

        var videoTracks: [AVAssetTrack] = []
        var audioTracks: [AVAssetTrack] = []
        var hasUnsupportedTracks = false

        for track in tracks {
            switch track.mediaType {
            case .video:
                videoTracks.append(track)
            case .audio:
                audioTracks.append(track)
            default:
                hasUnsupportedTracks = true
            }
        }

        guard let videoTrack = videoTracks.first else {
            throw AssetInspectorError.noVideoTrack
        }

        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let displaySize = naturalSize.applying(preferredTransform)
        let displayWidth = Int(abs(displaySize.width).rounded())
        let displayHeight = Int(abs(displaySize.height).rounded())

        let formatDescriptions = try await videoTrack.load(.formatDescriptions)
        let videoCodec = fourCC(from: formatDescriptions.first)

        let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
        let minFrameDuration = try await videoTrack.load(.minFrameDuration)
        let frameDuration: CompatibilitySignature.Rational?
        if minFrameDuration.isValid && !minFrameDuration.isIndefinite && minFrameDuration.value > 0 {
            frameDuration = CompatibilitySignature.Rational(minFrameDuration)
        } else if nominalFrameRate > 0 {
            // Fallback: approximate frame duration from nominal rate (reduced later).
            let timescale: Int32 = 60_000
            let value = Int64((Double(timescale) / Double(nominalFrameRate)).rounded())
            frameDuration = CompatibilitySignature.Rational(value: value, timescale: timescale)
        } else {
            frameDuration = nil
        }

        // Use the track's media timescale — not timeRange.start.timescale (often 1 when start is zero).
        let naturalTimeScale = try await videoTrack.load(.naturalTimeScale)
        let videoTimescale: Int32? = naturalTimeScale == 0 ? nil : naturalTimeScale

        var audioCodec: String?
        var audioSampleRate: Double?
        var audioChannelCount: Int?
        var audioFormatFlags: UInt32?

        if let audioTrack = audioTracks.first {
            let audioFormats = try await audioTrack.load(.formatDescriptions)
            audioCodec = fourCC(from: audioFormats.first)
            if let description = audioFormats.first {
                let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
                audioSampleRate = asbd?.mSampleRate
                audioChannelCount = asbd.map { Int($0.mChannelsPerFrame) }
                audioFormatFlags = asbd?.mFormatFlags
            }
        }

        return CompatibilitySignature(
            videoTrackCount: videoTracks.count,
            audioTrackCount: audioTracks.count,
            hasUnsupportedTracks: hasUnsupportedTracks,
            videoCodec: videoCodec,
            videoDisplayWidth: displayWidth,
            videoDisplayHeight: displayHeight,
            videoPreferredTransform: CompatibilitySignature.TransformComponents(preferredTransform),
            videoFrameDuration: frameDuration,
            videoTimescale: videoTimescale,
            audioCodec: audioCodec,
            audioSampleRate: audioSampleRate,
            audioChannelCount: audioChannelCount,
            audioFormatFlags: audioFormatFlags
        )
    }

    // MARK: - Internals

    /// Loads duration + signature without peer comparison. Status is intrinsic topology only.
    nonisolated private static func loadInspection(url: URL, index: Int) async -> AssetInspectionResult {
        let asset = AVURLAsset(url: url)

        let duration: CMTime?
        do {
            let loaded = try await asset.load(.duration)
            duration = (loaded.isValid && !loaded.isIndefinite) ? loaded : nil
        } catch {
            duration = nil
        }

        do {
            let signature = try await makeSignature(for: asset)
            let status = intrinsicStatus(for: signature)
            return AssetInspectionResult(
                url: url,
                index: index,
                duration: duration,
                signature: signature,
                status: status
            )
        } catch AssetInspectorError.noVideoTrack {
            return AssetInspectionResult(
                url: url,
                index: index,
                duration: duration,
                signature: nil,
                status: .unsupported("Asset must have exactly 1 video track (found 0)")
            )
        } catch let AssetInspectorError.unreadable(detail) {
            return AssetInspectionResult(
                url: url,
                index: index,
                duration: duration,
                signature: nil,
                status: .unreadable(detail)
            )
        } catch {
            return AssetInspectionResult(
                url: url,
                index: index,
                duration: duration,
                signature: nil,
                status: .unreadable(error.localizedDescription)
            )
        }
    }

    /// Applies the documented reference rule to already-loaded inspections.
    nonisolated static func evaluate(loadedInspections: [AssetInspectionResult]) -> PreflightReport {
        guard !loadedInspections.isEmpty else {
            return PreflightReport(results: [])
        }

        var results = loadedInspections
        let reference = results[0]

        if reference.signature == nil {
            // Keep the loaded unreadable/unsupported status on the reference row.
            if case .compatible = reference.status {
                results[0].status = .unreadable("Reference asset metadata is unavailable")
            }
            for index in 1..<results.count {
                if results[index].signature == nil {
                    // Preserve per-row unreadable/unsupported from load.
                    continue
                }
                results[index].status = .unsupported("Cannot compare: reference asset is unreadable")
            }
            return PreflightReport(results: results)
        }

        let referenceSignature = reference.signature!
        let referenceTopologyReasons = topologyRejectionReasons(for: referenceSignature, role: .reference)
        if referenceTopologyReasons.isEmpty {
            results[0].status = .compatible
        } else {
            results[0].status = .unsupported(referenceTopologyReasons.joined(separator: "; "))
        }

        for index in 1..<results.count {
            if results[index].signature == nil {
                // Preserve unreadable / no-video status from load.
                continue
            }
            let candidate = results[index].signature!
            let mismatches = CompatibilityComparer.mismatches(
                between: referenceSignature,
                and: candidate
            )
            let rowMismatches = mismatches.filter { !isReferenceOnlyTopology($0) }
            if rowMismatches.isEmpty {
                results[index].status = .compatible
            } else if rowMismatches.contains(where: {
                if case .unsupportedTopology = $0 { return true }
                return false
            }) {
                // Topology failures (multi-audio, unsupported tracks, bad video count) win over
                // field mismatches so UI can treat the row as unsupported rather than merely mismatched.
                results[index].status = .unsupported(
                    rowMismatches.map(\.description).joined(separator: "; ")
                )
            } else {
                results[index].status = .mismatch(rowMismatches)
            }
        }

        return PreflightReport(results: results)
    }

    private enum TopologyRole {
        case reference
        case candidate
    }

    nonisolated private static func intrinsicStatus(for signature: CompatibilitySignature) -> AssetRowStatus {
        // Prefer neutral wording for single-asset inspect (no reference/candidate role).
        var reasons: [String] = []
        if signature.hasUnsupportedTracks {
            reasons.append("Asset has unsupported tracks")
        }
        if signature.videoTrackCount != 1 {
            reasons.append("Asset must have exactly 1 video track (found \(signature.videoTrackCount))")
        }
        if signature.audioTrackCount > 1 {
            reasons.append("Asset must have at most 1 audio track (found \(signature.audioTrackCount))")
        }
        if reasons.isEmpty {
            return .compatible
        }
        return .unsupported(reasons.joined(separator: "; "))
    }

    nonisolated private static func topologyRejectionReasons(
        for signature: CompatibilitySignature,
        role: TopologyRole
    ) -> [String] {
        let label = role == .reference ? "reference" : "candidate"
        var reasons: [String] = []
        if signature.hasUnsupportedTracks {
            reasons.append("\(label) asset has unsupported tracks")
        }
        if signature.videoTrackCount != 1 {
            reasons.append("\(label) must have exactly 1 video track (found \(signature.videoTrackCount))")
        }
        if signature.audioTrackCount > 1 {
            reasons.append("\(label) must have at most 1 audio track (found \(signature.audioTrackCount))")
        }
        return reasons
    }

    nonisolated private static func isReferenceOnlyTopology(_ mismatch: CompatibilityMismatch) -> Bool {
        if case .unsupportedTopology(let detail) = mismatch {
            return detail.hasPrefix("reference ")
        }
        return false
    }

    private static func fourCC(from formatDescription: CMFormatDescription?) -> String? {
        guard let formatDescription else { return nil }
        let subType = CMFormatDescriptionGetMediaSubType(formatDescription)
        return fourCCString(subType)
    }

    static func fourCCString(_ value: FourCharCode) -> String {
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
