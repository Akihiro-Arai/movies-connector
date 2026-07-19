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
    /// Number of audio tracks that would be inserted (v1 allows 0 or 1; all inputs must match).
    var audioTrackCount: Int
    /// True when any non video/audio track exists (timecode, subtitle, metadata media, etc.).
    var hasUnsupportedTracks: Bool

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

    // MARK: - Audio

    /// Normalized audio codec FourCC (e.g. "aac ", "lpcm"). Lowercased / space-padded FourCC as string.
    var audioCodec: String?
    var audioSampleRate: Double?
    var audioChannelCount: Int?
    /// Audio format flags when present (e.g. LPCM layout); nil when not applicable.
    var audioFormatFlags: UInt32?

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
    case audioCodec(String?, String?)
    case audioSampleRate(Double?, Double?)
    case audioChannelCount(Int?, Int?)
    case audioFormatFlags(UInt32?, UInt32?)

    var description: String {
        switch self {
        case .unsupportedTopology(let detail):
            return "Unsupported track layout: \(detail)"
        case .videoTrackCount(let a, let b):
            return "Video track count mismatch (\(a) vs \(b))"
        case .audioTrackCount(let a, let b):
            return "Audio track count mismatch (\(a) vs \(b))"
        case .videoCodec(let a, let b):
            return "Video codec mismatch (\(Self.display(a)) vs \(Self.display(b)))"
        case .videoDisplaySize(let a, let b):
            return "Video display size mismatch (\(a) vs \(b))"
        case .videoPreferredTransform:
            return "Video preferred transform mismatch"
        case .videoFrameDuration(let a, let b):
            return "Video frame duration mismatch (\(Self.display(a)) vs \(Self.display(b)))"
        case .videoTimescale(let a, let b):
            return "Video timescale mismatch (\(Self.display(a)) vs \(Self.display(b)))"
        case .audioCodec(let a, let b):
            return "Audio codec mismatch (\(Self.display(a)) vs \(Self.display(b)))"
        case .audioSampleRate(let a, let b):
            return "Audio sample rate mismatch (\(Self.display(a)) vs \(Self.display(b)))"
        case .audioChannelCount(let a, let b):
            return "Audio channel count mismatch (\(Self.display(a)) vs \(Self.display(b)))"
        case .audioFormatFlags(let a, let b):
            return "Audio format flags mismatch (\(Self.display(a)) vs \(Self.display(b)))"
        }
    }

    private static func display<T>(_ value: T?) -> String {
        value.map { "\($0)" } ?? "nil"
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
        if lhs.audioCodec != rhs.audioCodec {
            results.append(.audioCodec(lhs.audioCodec, rhs.audioCodec))
        }
        if !almostEqual(lhs.audioSampleRate, rhs.audioSampleRate) {
            results.append(.audioSampleRate(lhs.audioSampleRate, rhs.audioSampleRate))
        }
        if lhs.audioChannelCount != rhs.audioChannelCount {
            results.append(.audioChannelCount(lhs.audioChannelCount, rhs.audioChannelCount))
        }
        if lhs.audioFormatFlags != rhs.audioFormatFlags {
            results.append(.audioFormatFlags(lhs.audioFormatFlags, rhs.audioFormatFlags))
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
