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
    /// Test seam: invoked at the start of each inspection load (cancellation injection).
    static var beforeLoadInspectionForTesting: (@Sendable (URL) async throws -> Void)?

    static func resetForTesting() {
        beforeLoadInspectionForTesting = nil
    }

    /// Inspect a single asset: duration + signature when readable, with intrinsic topology status.
    /// Does not compare against peers; use `preflight(urls:)` for ordered set evaluation.
    /// Propagates `CancellationError` rather than mapping it to `.unreadable`.
    nonisolated static func inspect(_ url: URL, index: Int = 0) async throws -> AssetInspectionResult {
        try await loadInspection(url: url, index: index)
    }

    /// Batch preflight for an ordered input set. The first URL is the reference
    /// (`docs/COMPATIBILITY.md`). Re-call whenever items are added, removed, or reordered.
    /// Preserves the caller's input order in `PreflightReport.results`.
    /// Propagates `CancellationError` from AV loads; call `Task.checkCancellation()` before judgment.
    nonisolated static func preflight(urls: [URL]) async throws -> PreflightReport {
        var loaded: [AssetInspectionResult] = []
        loaded.reserveCapacity(urls.count)
        for (index, url) in urls.enumerated() {
            try Task.checkCancellation()
            loaded.append(try await loadInspection(url: url, index: index))
        }
        try Task.checkCancellation()
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
        let report = try await preflight(urls: urls)
        try Task.checkCancellation()
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
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AssetInspectorError.unreadable(error.localizedDescription)
        }
        try Task.checkCancellation()

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
                // Photos / iPhone movies often carry metadata/timecode side-cars.
                if !isPassthroughIgnorableTrack(track.mediaType) {
                    hasUnsupportedTracks = true
                }
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

        // Signature fields describe the first audio track (exporterExporter inserts at most one).
        // `audioTrackCount` still reports every audio track so multi-audio is rejected.
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

        // Report the true audio track count so multi-audio is rejected (v1 cannot
        // passthrough every audio track). Only metadata/timecode side-cars are ignorable.
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

    /// Side-car tracks that are common on phone/Photos movies and never inserted by JoinExporter.
    /// Photos / iPhone often attach non-rendered metadata/timecode side-cars.
    /// User-visible text tracks (subtitle / CC / text) are NOT ignorable — they must reject.
    nonisolated static func isPassthroughIgnorableTrack(_ mediaType: AVMediaType) -> Bool {
        switch mediaType {
        case .metadata, .timecode:
            return true
        default:
            return false
        }
    }

    /// Loads duration + signature without peer comparison. Status is intrinsic topology only.
    /// Rethrows `CancellationError` before mapping other failures to unreadable/unsupported.
    nonisolated private static func loadInspection(url: URL, index: Int) async throws -> AssetInspectionResult {
        if let beforeLoadInspectionForTesting {
            try await beforeLoadInspectionForTesting(url)
        }

        let asset = AVURLAsset(url: url)

        let duration: CMTime?
        do {
            let loaded = try await asset.load(.duration)
            duration = (loaded.isValid && !loaded.isIndefinite) ? loaded : nil
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            duration = nil
        }

        try Task.checkCancellation()

        do {
            let signature = try await makeSignature(for: asset)
            try Task.checkCancellation()
            let status = intrinsicStatus(for: signature)
            return AssetInspectionResult(
                url: url,
                index: index,
                duration: duration,
                signature: signature,
                status: status
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch AssetInspectorError.noVideoTrack {
            return AssetInspectionResult(
                url: url,
                index: index,
                duration: duration,
                signature: nil,
                status: .unsupported(
                    L10n.string("compat.asset_video_track_count \(Int64(0))")
                )
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
                results[0].status = .unreadable(L10n.string("compat.reference_unavailable"))
            }
            for index in 1..<results.count {
                if results[index].signature == nil {
                    // Preserve per-row unreadable/unsupported from load.
                    continue
                }
                results[index].status = .unsupported(L10n.string("compat.cannot_compare_reference"))
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
            reasons.append(L10n.string("compat.asset_unsupported_tracks"))
        }
        if signature.videoTrackCount != 1 {
            reasons.append(
                L10n.string("compat.asset_video_track_count \(Int64(signature.videoTrackCount))")
            )
        }
        if signature.audioTrackCount > 1 {
            reasons.append(
                L10n.string("compat.asset_audio_track_count \(Int64(signature.audioTrackCount))")
            )
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
        var reasons: [String] = []
        if signature.hasUnsupportedTracks {
            switch role {
            case .reference:
                reasons.append(L10n.string("compat.reference_unsupported_tracks"))
            case .candidate:
                reasons.append(L10n.string("compat.candidate_unsupported_tracks"))
            }
        }
        if signature.videoTrackCount != 1 {
            switch role {
            case .reference:
                reasons.append(
                    L10n.string(
                        "compat.reference_video_track_count \(Int64(signature.videoTrackCount))"
                    )
                )
            case .candidate:
                reasons.append(
                    L10n.string(
                        "compat.candidate_video_track_count \(Int64(signature.videoTrackCount))"
                    )
                )
            }
        }
        if signature.audioTrackCount > 1 {
            switch role {
            case .reference:
                reasons.append(
                    L10n.string(
                        "compat.reference_audio_track_count \(Int64(signature.audioTrackCount))"
                    )
                )
            case .candidate:
                reasons.append(
                    L10n.string(
                        "compat.candidate_audio_track_count \(Int64(signature.audioTrackCount))"
                    )
                )
            }
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
