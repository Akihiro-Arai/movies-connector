import CoreMedia
import XCTest
@testable import MoviesConnector

final class CompatibilitySignatureTests: XCTestCase {
    func testIdenticalSignaturesAreCompatible() {
        let signature = sampleSignature()
        XCTAssertTrue(CompatibilityComparer.areCompatible(signature, signature))
        XCTAssertTrue(CompatibilityComparer.mismatches(between: signature, and: signature).isEmpty)
    }

    func testVideoCodecMismatchIsRejected() {
        var a = sampleSignature()
        var b = sampleSignature()
        a.videoCodec = "hvc1"
        b.videoCodec = "avc1"

        let mismatches = CompatibilityComparer.mismatches(between: a, and: b)
        XCTAssertTrue(mismatches.contains(.videoCodec("hvc1", "avc1")))
        XCTAssertFalse(CompatibilityComparer.areCompatible(a, b))
    }

    func testAudioTrackCountMismatchIsRejected() {
        var a = sampleSignature()
        var b = sampleSignature()
        b.audioTracks = []

        let mismatches = CompatibilityComparer.mismatches(between: a, and: b)
        XCTAssertTrue(mismatches.contains(.audioTrackCount(1, 0)))
    }

    func testMatchingTwoAudioSignaturesAreCompatible() {
        let a = dualAudioSignature()
        let b = dualAudioSignature()
        XCTAssertEqual(a.audioTrackCount, 2)
        XCTAssertTrue(CompatibilityComparer.areCompatible(a, b))
        XCTAssertTrue(CompatibilityComparer.mismatches(between: a, and: b).isEmpty)
    }

    func testTwoVersusOneAudioTrackCountIsRejected() {
        let reference = dualAudioSignature()
        let candidate = sampleSignature()

        let mismatches = CompatibilityComparer.mismatches(between: reference, and: candidate)
        XCTAssertTrue(mismatches.contains(.audioTrackCount(2, 1)))
        XCTAssertFalse(
            mismatches.contains(where: {
                if case .unsupportedTopology(let detail) = $0 {
                    return detail.contains("at most 1 audio track")
                }
                return false
            })
        )
    }

    func testSecondAudioTrackCodecMismatchIdentifiesTrack() {
        var reference = dualAudioSignature()
        var candidate = dualAudioSignature()
        candidate.audioTracks[1].codec = "aac"

        let mismatches = CompatibilityComparer.mismatches(between: reference, and: candidate)
        XCTAssertTrue(mismatches.contains(.audioCodec(track: 1, "apac", "aac")))
        XCTAssertEqual(
            CompatibilityMismatch.audioCodec(track: 1, "apac", "aac").description,
            "Audio track[1] codec mismatch (apac vs aac)"
        )
        XCTAssertFalse(mismatches.contains(where: {
            if case .audioCodec(let track, _, _) = $0 { return track == 0 }
            return false
        }))
    }

    func testZeroAudioSignaturesRemainCompatible() {
        let a = zeroAudioSignature()
        let b = zeroAudioSignature()
        XCTAssertEqual(a.audioTrackCount, 0)
        XCTAssertTrue(CompatibilityComparer.areCompatible(a, b))
    }

    func testOneAudioSignaturesRemainCompatible() {
        let a = sampleSignature()
        let b = sampleSignature()
        XCTAssertEqual(a.audioTrackCount, 1)
        XCTAssertTrue(CompatibilityComparer.areCompatible(a, b))
    }

    func testEvaluateMarksAudioCountMismatchAsMismatchNotUnsupportedTopology() {
        let reference = sampleSignature()
        var candidate = dualAudioSignature()
        candidate.videoCodec = reference.videoCodec
        candidate.videoDisplayWidth = reference.videoDisplayWidth
        candidate.videoDisplayHeight = reference.videoDisplayHeight
        candidate.videoPreferredTransform = reference.videoPreferredTransform
        candidate.videoFrameDuration = reference.videoFrameDuration
        candidate.videoTimescale = reference.videoTimescale

        let loaded = [
            AssetInspectionResult(
                url: URL(fileURLWithPath: "/ref.mov"),
                index: 0,
                duration: CMTime(value: 1, timescale: 1),
                signature: reference,
                status: .compatible
            ),
            AssetInspectionResult(
                url: URL(fileURLWithPath: "/cand.mov"),
                index: 1,
                duration: CMTime(value: 1, timescale: 1),
                signature: candidate,
                status: .compatible
            ),
        ]
        let report = AssetInspector.evaluate(loadedInspections: loaded)
        XCTAssertFalse(report.canExport)
        XCTAssertEqual(report.results[0].status, .compatible)
        guard case .mismatch(let mismatches) = report.results[1].status else {
            return XCTFail("Expected mismatch for audio count, got \(report.results[1].status)")
        }
        XCTAssertTrue(mismatches.contains(.audioTrackCount(1, 2)))
    }

    func testEvaluateMarksMatchingMultiAudioCompatible() {
        let reference = dualAudioSignature()
        let candidate = dualAudioSignature()
        let loaded = [
            AssetInspectionResult(
                url: URL(fileURLWithPath: "/ref.mov"),
                index: 0,
                duration: CMTime(value: 1, timescale: 1),
                signature: reference,
                status: .compatible
            ),
            AssetInspectionResult(
                url: URL(fileURLWithPath: "/cand.mov"),
                index: 1,
                duration: CMTime(value: 1, timescale: 1),
                signature: candidate,
                status: .compatible
            ),
        ]
        let report = AssetInspector.evaluate(loadedInspections: loaded)
        XCTAssertTrue(report.canExport)
        XCTAssertEqual(report.results[0].status, .compatible)
        XCTAssertEqual(report.results[1].status, .compatible)
    }

    func testDisplaySizeMismatchIsRejected() {
        let a = sampleSignature()
        var b = sampleSignature()
        b.videoDisplayWidth = 1280
        b.videoDisplayHeight = 720

        let mismatches = CompatibilityComparer.mismatches(between: a, and: b)
        XCTAssertEqual(mismatches.count, 1)
        XCTAssertEqual(
            mismatches.first,
            .videoDisplaySize("1920x1080", "1280x720")
        )
    }

    func testFrameDurationMismatchIsRejected() {
        var a = sampleSignature()
        var b = sampleSignature()
        a.videoFrameDuration = CompatibilitySignature.Rational(value: 1, timescale: 30)
        b.videoFrameDuration = CompatibilitySignature.Rational(value: 1, timescale: 24)

        let mismatches = CompatibilityComparer.mismatches(between: a, and: b)
        XCTAssertTrue(
            mismatches.contains(.videoFrameDuration("1/30", "1/24"))
        )
    }

    func testNearThirtyFPSFrameDurationsAreTolerated() {
        var a = sampleSignature()
        var b = sampleSignature()
        // Desktop iPhone set: 19/600 ≈ 31.6fps vs 20/600 = 30fps (~5%).
        a.videoFrameDuration = CompatibilitySignature.Rational(value: 19, timescale: 600)
        b.videoFrameDuration = CompatibilitySignature.Rational(value: 20, timescale: 600)

        XCTAssertTrue(CompatibilityComparer.mismatches(between: a, and: b).isEmpty)
        XCTAssertTrue(CompatibilityComparer.areCompatible(a, b))
    }

    func testVideoTimescaleMismatchIsRejected() {
        var a = sampleSignature()
        var b = sampleSignature()
        a.videoTimescale = 30_000
        b.videoTimescale = 24_000

        let mismatches = CompatibilityComparer.mismatches(between: a, and: b)
        XCTAssertTrue(mismatches.contains(.videoTimescale(30_000, 24_000)))
    }

    func testPreferredTransformMismatchIsRejected() {
        var a = sampleSignature()
        var b = sampleSignature()
        a.videoPreferredTransform = .identity
        b.videoPreferredTransform = CompatibilitySignature.TransformComponents(
            a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0
        )

        let mismatches = CompatibilityComparer.mismatches(between: a, and: b)
        XCTAssertTrue(mismatches.contains(.videoPreferredTransform))
    }

    func testAudioCodecMismatchIsRejected() {
        var a = sampleSignature()
        var b = sampleSignature()
        a.audioTracks[0].codec = "aac"
        b.audioTracks[0].codec = "lpcm"

        let mismatches = CompatibilityComparer.mismatches(between: a, and: b)
        XCTAssertTrue(mismatches.contains(.audioCodec(track: 0, "aac", "lpcm")))
    }

    func testAudioSampleRateMismatchIsRejected() {
        var a = sampleSignature()
        var b = sampleSignature()
        a.audioTracks[0].sampleRate = 48_000
        b.audioTracks[0].sampleRate = 44_100

        let mismatches = CompatibilityComparer.mismatches(between: a, and: b)
        XCTAssertTrue(mismatches.contains(.audioSampleRate(track: 0, 48_000, 44_100)))
    }

    func testAudioSampleRateEpsilonTreatsNearEqualAsMatch() {
        var a = sampleSignature()
        var b = sampleSignature()
        a.audioTracks[0].sampleRate = 48_000
        b.audioTracks[0].sampleRate = 48_000 + 1e-7

        XCTAssertTrue(CompatibilityComparer.areCompatible(a, b))
    }

    func testAudioChannelCountMismatchIsRejected() {
        var a = sampleSignature()
        var b = sampleSignature()
        a.audioTracks[0].channelCount = 2
        b.audioTracks[0].channelCount = 1

        let mismatches = CompatibilityComparer.mismatches(between: a, and: b)
        XCTAssertTrue(mismatches.contains(.audioChannelCount(track: 0, 2, 1)))
    }

    func testAudioFormatFlagsMismatchIsRejected() {
        var a = sampleSignature()
        var b = sampleSignature()
        a.audioTracks[0].formatFlags = 0
        b.audioTracks[0].formatFlags = 12

        let mismatches = CompatibilityComparer.mismatches(between: a, and: b)
        XCTAssertTrue(mismatches.contains(.audioFormatFlags(track: 0, 0, 12)))
    }

    func testUnsupportedTracksOnCandidateAreRejected() {
        var a = sampleSignature()
        var b = sampleSignature()
        b.hasUnsupportedTracks = true

        let mismatches = CompatibilityComparer.mismatches(between: a, and: b)
        XCTAssertTrue(
            mismatches.contains(
                .unsupportedTopology("candidate asset has unsupported tracks")
            )
        )
    }

    func testUnsupportedTracksOnReferenceAreRejected() {
        var a = sampleSignature()
        var b = sampleSignature()
        a.hasUnsupportedTracks = true

        let mismatches = CompatibilityComparer.mismatches(between: a, and: b)
        XCTAssertTrue(
            mismatches.contains(
                .unsupportedTopology("reference asset has unsupported tracks")
            )
        )
    }

    func testZeroVideoTracksIsUnsupportedTopology() {
        var a = sampleSignature()
        var b = sampleSignature()
        a.videoTrackCount = 0

        let mismatches = CompatibilityComparer.mismatches(between: a, and: b)
        XCTAssertTrue(
            mismatches.contains(
                .unsupportedTopology("reference must have exactly 1 video track (found 0)")
            )
        )
    }

    func testRationalReduction() {
        let rational = CompatibilitySignature.Rational(value: 2002, timescale: 60_000)
        XCTAssertEqual(rational.value, 1001)
        XCTAssertEqual(rational.timescale, 30_000)
    }

    func testTransformQuantizationTreatsNearIdentityAsEqual() {
        let a = CompatibilitySignature.TransformComponents(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)
        let b = CompatibilitySignature.TransformComponents(
            a: 1.0000004,
            b: 0,
            c: 0,
            d: 1,
            tx: 0,
            ty: 0
        )
        XCTAssertEqual(a, b)
    }

    func testMismatchDescriptionsMatchDocumentedExamples() {
        XCTAssertEqual(
            CompatibilityMismatch.videoCodec("hvc1", "avc1").description,
            "Video codec mismatch (hvc1 vs avc1)"
        )
        XCTAssertEqual(
            CompatibilityMismatch.videoDisplaySize("1920x1080", "1280x720").description,
            "Video display size mismatch (1920x1080 vs 1280x720)"
        )
        XCTAssertEqual(
            CompatibilityMismatch.audioChannelCount(track: 0, 2, 1).description,
            "Audio track[0] channel count mismatch (2 vs 1)"
        )
        XCTAssertEqual(
            CompatibilityMismatch.audioTrackCount(1, 0).description,
            "Audio track count mismatch (1 vs 0)"
        )
        XCTAssertEqual(
            CompatibilityMismatch.videoPreferredTransform.description,
            "Video preferred transform mismatch"
        )
    }

    private func sampleSignature() -> CompatibilitySignature {
        CompatibilitySignature(
            videoTrackCount: 1,
            audioTracks: [
                .init(codec: "aac", sampleRate: 48_000, channelCount: 2, formatFlags: 0),
            ],
            hasUnsupportedTracks: false,
            videoCodec: "hvc1",
            videoDisplayWidth: 1920,
            videoDisplayHeight: 1080,
            videoPreferredTransform: .identity,
            videoFrameDuration: CompatibilitySignature.Rational(value: 1001, timescale: 30_000),
            videoTimescale: 30_000
        )
    }

    private func dualAudioSignature() -> CompatibilitySignature {
        CompatibilitySignature(
            videoTrackCount: 1,
            audioTracks: [
                .init(codec: "aac", sampleRate: 48_000, channelCount: 2, formatFlags: 0),
                .init(codec: "apac", sampleRate: 48_000, channelCount: 2, formatFlags: 0),
            ],
            hasUnsupportedTracks: false,
            videoCodec: "hvc1",
            videoDisplayWidth: 1920,
            videoDisplayHeight: 1080,
            videoPreferredTransform: .identity,
            videoFrameDuration: CompatibilitySignature.Rational(value: 1001, timescale: 30_000),
            videoTimescale: 30_000
        )
    }

    private func zeroAudioSignature() -> CompatibilitySignature {
        CompatibilitySignature(
            videoTrackCount: 1,
            audioTracks: [],
            hasUnsupportedTracks: false,
            videoCodec: "hvc1",
            videoDisplayWidth: 1920,
            videoDisplayHeight: 1080,
            videoPreferredTransform: .identity,
            videoFrameDuration: CompatibilitySignature.Rational(value: 1001, timescale: 30_000),
            videoTimescale: 30_000
        )
    }
}
