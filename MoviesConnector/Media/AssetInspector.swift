import AVFoundation
import CoreMedia
import Foundation

enum AssetInspectorError: Error, LocalizedError, Equatable {
    case noVideoTrack
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "Asset has no video track"
        case .unreadable(let detail):
            return "Asset is unreadable: \(detail)"
        }
    }
}

enum AssetInspector {
    /// Loads track metadata and builds a `CompatibilitySignature` for rejection checks on add.
    static func makeSignature(for url: URL) async throws -> CompatibilitySignature {
        let asset = AVURLAsset(url: url)
        return try await makeSignature(for: asset)
    }

    static func makeSignature(for asset: AVAsset) async throws -> CompatibilitySignature {
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
