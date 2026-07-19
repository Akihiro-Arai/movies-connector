import XCTest
@testable import MoviesConnector

@MainActor
final class JoinAdapterTests: XCTestCase {
    override func tearDown() {
        UserSelectedURLAccess.resetForTesting()
        MovieOpenPanel.resetForTesting()
        MovieSavePanel.resetForTesting()
        super.tearDown()
    }

    func testDefaultInspectorUsesPreparedAccessAndSurfacesDenial() async {
        let url = URL(fileURLWithPath: "/tmp/join-denied.mov")
        var started: [URL] = []
        SecurityScopedAccess.startAccessingForTesting = { candidate in
            started.append(candidate)
            return false
        }
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

        do {
            _ = try await DefaultAssetInspector().inspect(url: url)
            XCTFail("Expected security-scoped access denial")
        } catch let error as UserSelectedURLAccessError {
            XCTAssertEqual(error, .securityScopedAccessDenied(url))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(started, [url])
    }

    func testDefaultInspectorSurfacesICloudUnavailable() async {
        let url = URL(fileURLWithPath: "/tmp/icloud-clip.mov")
        SecurityScopedAccess.startAccessingForTesting = { _ in true }
        SecurityScopedAccess.stopAccessingForTesting = { _ in }
        UserSelectedURLAccess.startDownloadingForTesting = { _ in }
        UserSelectedURLAccess.ubiquitousItemStateForTesting = { _ in
            UbiquitousItemState(
                isUbiquitous: true,
                downloadingStatus: .notDownloaded,
                isDownloading: false,
                downloadingErrorDescription: nil,
                isReadable: false
            )
        }

        do {
            _ = try await DefaultAssetInspector().inspect(url: url)
            XCTFail("Expected iCloud unavailable error")
        } catch let error as UserSelectedURLAccessError {
            XCTAssertEqual(error, .iCloudItemUnavailable(url))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDefaultExporterUsesPreparedAccessAndSurfacesDenial() async {
        let input = URL(fileURLWithPath: "/tmp/in.mov")
        let output = URL(fileURLWithPath: "/tmp/out.mov")
        var started: [URL] = []
        SecurityScopedAccess.startAccessingForTesting = { url in
            started.append(url)
            return url != output
        }
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

        do {
            try await DefaultJoinExporter().join(inputURLs: [input], outputURL: output)
            XCTFail("Expected security-scoped access denial")
        } catch let error as UserSelectedURLAccessError {
            XCTAssertEqual(error, .securityScopedAccessDenied(output))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(started, [input, output])
    }

    func testSystemVideoFileSelectorUsesMovieOpenPanel() async {
        let urls = [
            URL(fileURLWithPath: "/Movies/a.mov"),
            URL(fileURLWithPath: "/Movies/b.mp4"),
        ]
        MovieOpenPanel.presentForTesting = { urls }

        let selected = await SystemVideoFileSelector().selectVideos()
        XCTAssertEqual(selected, urls)
    }

    func testSystemVideoFileSelectorCancelReturnsEmpty() async {
        MovieOpenPanel.presentForTesting = { nil }
        let selected = await SystemVideoFileSelector().selectVideos()
        XCTAssertEqual(selected, [])
    }

    func testSystemOutputSelectorUsesMovieSavePanelNormalization() async {
        MovieSavePanel.presentForTesting = { suggested in
            XCTAssertEqual(suggested, "clip-joined.mov")
            return URL(fileURLWithPath: "/Exports/clip-joined.mp4")
        }

        let url = await SystemOutputDestinationSelector()
            .selectOutputDestination(suggestedName: "clip-joined.mov")
        XCTAssertEqual(url?.path, "/Exports/clip-joined.mov")
    }
}
