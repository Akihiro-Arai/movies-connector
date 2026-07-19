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
