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
        a.audioTrackCount = 1
        b.audioTrackCount = 0
        b.audioCodec = nil
        b.audioSampleRate = nil
        b.audioChannelCount = nil
        b.audioFormatFlags = nil

        let mismatches = CompatibilityComparer.mismatches(between: a, and: b)
        XCTAssertTrue(mismatches.contains(.audioTrackCount(1, 0)))
    }

    func testMultiAudioOnReferenceIsUnsupportedTopology() {
        var reference = sampleSignature()
        var candidate = sampleSignature()
        reference.audioTrackCount = 2
        candidate.audioTrackCount = 2

        let mismatches = CompatibilityComparer.mismatches(between: reference, and: candidate)
        XCTAssertTrue(
            mismatches.contains(
                .unsupportedTopology("reference must have at most 1 audio track (found 2)")
            )
        )
        XCTAssertTrue(
            mismatches.contains(
                .unsupportedTopology("candidate must have at most 1 audio track (found 2)")
            )
        )
        XCTAssertFalse(CompatibilityComparer.areCompatible(reference, candidate))
    }

    func testMultiAudioOnCandidateOnlyIsUnsupportedTopology() {
        var reference = sampleSignature()
        var candidate = sampleSignature()
        reference.audioTrackCount = 1
        candidate.audioTrackCount = 3

        let mismatches = CompatibilityComparer.mismatches(between: reference, and: candidate)
        XCTAssertTrue(
            mismatches.contains(
                .unsupportedTopology("candidate must have at most 1 audio track (found 3)")
            )
        )
        XCTAssertTrue(mismatches.contains(.audioTrackCount(1, 3)))
        XCTAssertFalse(
            mismatches.contains(where: {
                if case .unsupportedTopology(let detail) = $0 {
                    return detail.contains("reference must have at most 1 audio track")
                }
                return false
            })
        )
    }

    func testSingleInputStyleSignatureRejectsMultiAudioAgainstItself() {
        var signature = sampleSignature()
        signature.audioTrackCount = 2
        let mismatches = CompatibilityComparer.mismatches(between: signature, and: signature)
        XCTAssertTrue(
            mismatches.contains(
                .unsupportedTopology("reference must have at most 1 audio track (found 2)")
            )
        )
        XCTAssertTrue(
            mismatches.contains(
                .unsupportedTopology("candidate must have at most 1 audio track (found 2)")
            )
        )
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
        a.audioCodec = "aac"
        b.audioCodec = "lpcm"

        let mismatches = CompatibilityComparer.mismatches(between: a, and: b)
        XCTAssertTrue(mismatches.contains(.audioCodec("aac", "lpcm")))
    }

    func testAudioSampleRateMismatchIsRejected() {
        var a = sampleSignature()
        var b = sampleSignature()
        a.audioSampleRate = 48_000
        b.audioSampleRate = 44_100

        let mismatches = CompatibilityComparer.mismatches(between: a, and: b)
        XCTAssertTrue(mismatches.contains(.audioSampleRate(48_000, 44_100)))
    }

    func testAudioSampleRateEpsilonTreatsNearEqualAsMatch() {
        var a = sampleSignature()
        var b = sampleSignature()
        a.audioSampleRate = 48_000
        b.audioSampleRate = 48_000 + 1e-7

        XCTAssertTrue(CompatibilityComparer.areCompatible(a, b))
    }

    func testAudioChannelCountMismatchIsRejected() {
        var a = sampleSignature()
        var b = sampleSignature()
        a.audioChannelCount = 2
        b.audioChannelCount = 1

        let mismatches = CompatibilityComparer.mismatches(between: a, and: b)
        XCTAssertTrue(mismatches.contains(.audioChannelCount(2, 1)))
    }

    func testAudioFormatFlagsMismatchIsRejected() {
        var a = sampleSignature()
        var b = sampleSignature()
        a.audioFormatFlags = 0
        b.audioFormatFlags = 12

        let mismatches = CompatibilityComparer.mismatches(between: a, and: b)
        XCTAssertTrue(mismatches.contains(.audioFormatFlags(0, 12)))
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

    func testEvaluateMarksMultiAudioCandidateUnsupported() {
        let reference = sampleSignature()
        var candidate = sampleSignature()
        candidate.audioTrackCount = 2

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
        guard case .unsupported(let detail) = report.results[1].status else {
            return XCTFail("Expected unsupported multi-audio candidate, got \(report.results[1].status)")
        }
        XCTAssertTrue(detail.lowercased().contains("audio"))
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
            CompatibilityMismatch.audioChannelCount(2, 1).description,
            "Audio channel count mismatch (2 vs 1)"
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
            audioTrackCount: 1,
            hasUnsupportedTracks: false,
            videoCodec: "hvc1",
            videoDisplayWidth: 1920,
            videoDisplayHeight: 1080,
            videoPreferredTransform: .identity,
            videoFrameDuration: CompatibilitySignature.Rational(value: 1001, timescale: 30_000),
            videoTimescale: 30_000,
            audioCodec: "aac",
            audioSampleRate: 48_000,
            audioChannelCount: 2,
            audioFormatFlags: 0
        )
    }
}
