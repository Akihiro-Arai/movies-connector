import AVFoundation
import CoreMedia
import Foundation

/// Deterministic fingerprint of a media file's track topology for v1 passthrough joining.
///
/// Two assets are **compatible** when every normalized field below matches exactly.
/// Mismatches reject the join before export — v1 never re-encodes.
///
/// Full field list and normalization rules: `docs/COMPATIBILITY.md`.
struct CompatibilitySignature: Equatable, Hashable, Sendable {
    // MARK: - Container / topology

    /// Number of video tracks that would be inserted into the composition (v1 expects exactly 1).
    var videoTrackCount: Int
    /// Ordered audio-track fingerprints for passthrough (`N >= 0`). Count must match across inputs.
    var audioTracks: [AudioTrackSignature]
    /// True when a non-ignorable non-AV track exists. Metadata / timecode / text side-cars
    /// from Photos / iPhone are ignored and do not set this flag.
    var hasUnsupportedTracks: Bool

    /// Derived from `audioTracks.count` (`N >= 0`).
    var audioTrackCount: Int { audioTracks.count }

    // MARK: - Video

    /// Normalized video codec FourCC (e.g. "hvc1", "avc1"). Lowercased ASCII.
    var videoCodec: String?
    /// Encoded pixel dimensions after applying preferred transform (display size).
    var videoDisplayWidth: Int
    var videoDisplayHeight: Int
    /// `CGAffineTransform` components from the video track's preferred transform, quantized.
    var videoPreferredTransform: TransformComponents
    /// Nominal frame duration as a reduced rational (value/timescale). Nil if unavailable.
    var videoFrameDuration: Rational?
    /// Media timescale of the primary video track.
    var videoTimescale: Int32?

    // MARK: - Nested types

    /// Encoded parameters for one audio track (compared by index across inputs).
    struct AudioTrackSignature: Equatable, Hashable, Sendable {
        /// Normalized audio codec FourCC (e.g. "aac", "lpcm"). Lowercased / trimmed FourCC.
        var codec: String?
        var sampleRate: Double?
        var channelCount: Int?
        /// Audio format flags when present (e.g. LPCM layout); nil when not applicable.
        var formatFlags: UInt32?
    }

    struct TransformComponents: Equatable, Hashable, Sendable {
        var a: Double
        var b: Double
        var c: Double
        var d: Double
        var tx: Double
        var ty: Double

        static let identity = TransformComponents(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

        init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
            self.a = Self.quantize(a)
            self.b = Self.quantize(b)
            self.c = Self.quantize(c)
            self.d = Self.quantize(d)
            self.tx = Self.quantize(tx)
            self.ty = Self.quantize(ty)
        }

        init(_ transform: CGAffineTransform) {
            self.init(
                a: Double(transform.a),
                b: Double(transform.b),
                c: Double(transform.c),
                d: Double(transform.d),
                tx: Double(transform.tx),
                ty: Double(transform.ty)
            )
        }

        private static func quantize(_ value: Double) -> Double {
            (value * 1_000_000).rounded() / 1_000_000
        }
    }

    struct Rational: Equatable, Hashable, Sendable {
        var value: Int64
        var timescale: Int32

        init(value: Int64, timescale: Int32) {
            let reduced = Self.reduce(value: value, timescale: timescale)
            self.value = reduced.value
            self.timescale = reduced.timescale
        }

        init(_ time: CMTime) {
            self.init(value: time.value, timescale: time.timescale)
        }

        private static func reduce(value: Int64, timescale: Int32) -> (value: Int64, timescale: Int32) {
            guard value != 0, timescale != 0 else {
                return (value, timescale)
            }
            let g = gcd(abs(value), Int64(abs(timescale)))
            return (value / g, Int32(Int64(timescale) / g))
        }

        private static func gcd(_ a: Int64, _ b: Int64) -> Int64 {
            var a = a
            var b = b
            while b != 0 {
                let t = b
                b = a % b
                a = t
            }
            return a
        }
    }
}

enum CompatibilityMismatch: Equatable, Sendable, CustomStringConvertible {
    case unsupportedTopology(String)
    case videoTrackCount(Int, Int)
    case audioTrackCount(Int, Int)
    case videoCodec(String?, String?)
    case videoDisplaySize(String, String)
    case videoPreferredTransform
    case videoFrameDuration(String?, String?)
    case videoTimescale(Int32?, Int32?)
    case audioCodec(track: Int, String?, String?)
    case audioSampleRate(track: Int, Double?, Double?)
    case audioChannelCount(track: Int, Int?, Int?)
    case audioFormatFlags(track: Int, UInt32?, UInt32?)

    /// Stable English text for logs, exporter errors, and unit tests.
    var description: String {
        localizedDescription(locale: Locale(identifier: "en"))
    }

    /// Presentation-time localization (#22).
    var localizedDescription: String {
        localizedDescription(locale: L10n.locale)
    }

    func localizedDescription(locale: Locale) -> String {
        switch self {
        case .unsupportedTopology(let detail):
            return Self.localizedTopologyDetail(detail, locale: locale)
        case .videoTrackCount(let a, let b):
            return L10n.string(
                "compat.video_track_count \(Int64(a)) \(Int64(b))",
                locale: locale
            )
        case .audioTrackCount(let a, let b):
            return L10n.string(
                "compat.audio_track_count \(Int64(a)) \(Int64(b))",
                locale: locale
            )
        case .videoCodec(let a, let b):
            return L10n.string(
                "compat.video_codec \(Self.display(a)) \(Self.display(b))",
                locale: locale
            )
        case .videoDisplaySize(let a, let b):
            return L10n.string("compat.video_display_size \(a) \(b)", locale: locale)
        case .videoPreferredTransform:
            return L10n.string("compat.video_transform", locale: locale)
        case .videoFrameDuration(let a, let b):
            return L10n.string(
                "compat.video_frame_duration \(Self.display(a)) \(Self.display(b))",
                locale: locale
            )
        case .videoTimescale(let a, let b):
            return L10n.string(
                "compat.video_timescale \(Self.display(a)) \(Self.display(b))",
                locale: locale
            )
        case .audioCodec(let track, let a, let b):
            return L10n.string(
                "compat.audio_codec \(Int64(track)) \(Self.display(a)) \(Self.display(b))",
                locale: locale
            )
        case .audioSampleRate(let track, let a, let b):
            return L10n.string(
                "compat.audio_sample_rate \(Int64(track)) \(Self.display(a)) \(Self.display(b))",
                locale: locale
            )
        case .audioChannelCount(let track, let a, let b):
            return L10n.string(
                "compat.audio_channel_count \(Int64(track)) \(Self.display(a)) \(Self.display(b))",
                locale: locale
            )
        case .audioFormatFlags(let track, let a, let b):
            return L10n.string(
                "compat.audio_format_flags \(Int64(track)) \(Self.display(a)) \(Self.display(b))",
                locale: locale
            )
        }
    }

    private static func display<T>(_ value: T?) -> String {
        value.map { "\($0)" } ?? "nil"
    }

    /// Maps stable English topology machine strings to catalog entries (#22).
    private static func localizedTopologyDetail(_ detail: String, locale: Locale) -> String {
        switch detail {
        case "reference asset has unsupported tracks":
            return L10n.string("compat.reference_unsupported_tracks", locale: locale)
        case "candidate asset has unsupported tracks":
            return L10n.string("compat.candidate_unsupported_tracks", locale: locale)
        default:
            break
        }
        if let count = parseFoundCount(
            prefix: "reference must have exactly 1 video track (found ",
            detail: detail
        ) {
            return L10n.string("compat.reference_video_track_count \(Int64(count))", locale: locale)
        }
        if let count = parseFoundCount(
            prefix: "candidate must have exactly 1 video track (found ",
            detail: detail
        ) {
            return L10n.string("compat.candidate_video_track_count \(Int64(count))", locale: locale)
        }
        return L10n.string("compat.topology \(detail)", locale: locale)
    }

    private static func parseFoundCount(prefix: String, detail: String) -> Int? {
        guard detail.hasPrefix(prefix), detail.hasSuffix(")") else { return nil }
        let start = detail.index(detail.startIndex, offsetBy: prefix.count)
        let end = detail.index(before: detail.endIndex)
        return Int(detail[start..<end])
    }
}

enum CompatibilityComparer {
    /// Returns concrete mismatch reasons; empty means compatible for passthrough join.
    static func mismatches(between lhs: CompatibilitySignature, and rhs: CompatibilitySignature) -> [CompatibilityMismatch] {
        var results: [CompatibilityMismatch] = []

        if lhs.hasUnsupportedTracks {
            results.append(.unsupportedTopology("reference asset has unsupported tracks"))
        }
        if rhs.hasUnsupportedTracks {
            results.append(.unsupportedTopology("candidate asset has unsupported tracks"))
        }
        if lhs.videoTrackCount != 1 || rhs.videoTrackCount != 1 {
            // v1 requires exactly one video track on every input.
            if lhs.videoTrackCount != rhs.videoTrackCount {
                results.append(.videoTrackCount(lhs.videoTrackCount, rhs.videoTrackCount))
            }
            if lhs.videoTrackCount != 1 {
                results.append(.unsupportedTopology("reference must have exactly 1 video track (found \(lhs.videoTrackCount))"))
            }
            if rhs.videoTrackCount != 1 {
                results.append(.unsupportedTopology("candidate must have exactly 1 video track (found \(rhs.videoTrackCount))"))
            }
        }
        if lhs.audioTrackCount != rhs.audioTrackCount {
            results.append(.audioTrackCount(lhs.audioTrackCount, rhs.audioTrackCount))
        }
        if lhs.videoCodec != rhs.videoCodec {
            results.append(.videoCodec(lhs.videoCodec, rhs.videoCodec))
        }
        if lhs.videoDisplayWidth != rhs.videoDisplayWidth || lhs.videoDisplayHeight != rhs.videoDisplayHeight {
            results.append(
                .videoDisplaySize(
                    "\(lhs.videoDisplayWidth)x\(lhs.videoDisplayHeight)",
                    "\(rhs.videoDisplayWidth)x\(rhs.videoDisplayHeight)"
                )
            )
        }
        if lhs.videoPreferredTransform != rhs.videoPreferredTransform {
            results.append(.videoPreferredTransform)
        }
        if lhs.videoFrameDuration != rhs.videoFrameDuration {
            results.append(
                .videoFrameDuration(
                    lhs.videoFrameDuration.map { "\($0.value)/\($0.timescale)" },
                    rhs.videoFrameDuration.map { "\($0.value)/\($0.timescale)" }
                )
            )
        }
        if lhs.videoTimescale != rhs.videoTimescale {
            results.append(.videoTimescale(lhs.videoTimescale, rhs.videoTimescale))
        }

        // Per-track audio compare only when counts match (count mismatch already recorded).
        if lhs.audioTrackCount == rhs.audioTrackCount {
            for index in lhs.audioTracks.indices {
                let left = lhs.audioTracks[index]
                let right = rhs.audioTracks[index]
                if left.codec != right.codec {
                    results.append(.audioCodec(track: index, left.codec, right.codec))
                }
                if !almostEqual(left.sampleRate, right.sampleRate) {
                    results.append(.audioSampleRate(track: index, left.sampleRate, right.sampleRate))
                }
                if left.channelCount != right.channelCount {
                    results.append(.audioChannelCount(track: index, left.channelCount, right.channelCount))
                }
                if left.formatFlags != right.formatFlags {
                    results.append(.audioFormatFlags(track: index, left.formatFlags, right.formatFlags))
                }
            }
        }

        return results
    }

    static func areCompatible(_ lhs: CompatibilitySignature, _ rhs: CompatibilitySignature) -> Bool {
        mismatches(between: lhs, and: rhs).isEmpty
    }

    private static func almostEqual(_ a: Double?, _ b: Double?) -> Bool {
        switch (a, b) {
        case (nil, nil):
            return true
        case let (a?, b?):
            return abs(a - b) < 0.000_001
        default:
            return false
        }
    }
}
