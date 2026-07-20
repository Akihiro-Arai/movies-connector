import AVFoundation
import XCTest
@testable import MoviesConnector

/// Manual / local experiment against `~/Desktop/movieconnector-debug`.
/// Skips cleanly when the folder is absent (CI).
final class DesktopDebugJoinTests: XCTestCase {
    func testDesktopDebugMoviesPassthroughJoinIfPresent() async throws {
        let directory = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Desktop/movieconnector-debug", isDirectory: true)
        let names = ["IMG_3501.MOV", "IMG_3502.MOV", "IMG_3503.MOV", "IMG_3514.MOV"]
        let urls = names.map { directory.appendingPathComponent($0) }
        let missing = urls.filter { !FileManager.default.fileExists(atPath: $0.path) }
        try XCTSkipIf(
            !missing.isEmpty,
            "Desktop debug movies not present: \(missing.map(\.lastPathComponent))"
        )

        let report = try await AssetInspector.preflight(urls: urls)
        XCTAssertTrue(report.canExport, report.formattedReasons.joined(separator: "; "))
        for result in report.results {
            XCTAssertEqual(
                result.status,
                .compatible,
                "\(result.url.lastPathComponent): \(result.status.reasons.joined(separator: "; "))"
            )
        }

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("desktop-debug-join-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: output) }

        let result = try await JoinExporter.join(
            inputURLs: urls,
            outputURL: output,
            replaceExistingDestination: true,
            progress: nil
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.outputURL.path))
        XCTAssertGreaterThan(result.outputDuration.seconds, 50)

        let outputAsset = AVURLAsset(url: result.outputURL)
        let audioTracks = try await outputAsset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 2, "Expected both AAC and APAC to be retained")
    }
}
