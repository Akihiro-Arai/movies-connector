import XCTest
@testable import MoviesConnector

@MainActor
final class MovieSavePanelTests: XCTestCase {
    override func tearDown() {
        MovieSavePanel.resetForTesting()
        MovieOpenPanel.resetForTesting()
        super.tearDown()
    }

    func testNormalizeOutputURLForcesMovExtension() {
        let bare = URL(fileURLWithPath: "/tmp/Joined")
        let mp4 = URL(fileURLWithPath: "/tmp/Joined.mp4")
        let mov = URL(fileURLWithPath: "/tmp/Joined.mov")
        let upper = URL(fileURLWithPath: "/tmp/Joined.MOV")

        XCTAssertEqual(
            MovieSavePanel.normalizeOutputURL(bare).path,
            "/tmp/Joined.mov"
        )
        XCTAssertEqual(
            MovieSavePanel.normalizeOutputURL(mp4).path,
            "/tmp/Joined.mov"
        )
        XCTAssertEqual(
            MovieSavePanel.normalizeOutputURL(mov).path,
            "/tmp/Joined.mov"
        )
        XCTAssertEqual(
            MovieSavePanel.normalizeOutputURL(upper).path,
            "/tmp/Joined.MOV"
        )
    }

    func testSuggestedFileNameNormalizesExtension() {
        XCTAssertEqual(MovieSavePanel.suggestedFileName(from: "Joined"), "Joined.mov")
        XCTAssertEqual(MovieSavePanel.suggestedFileName(from: "Joined.mp4"), "Joined.mov")
        XCTAssertEqual(MovieSavePanel.suggestedFileName(from: "Joined.mov"), "Joined.mov")
        XCTAssertEqual(MovieSavePanel.suggestedFileName(from: "  "), "Joined.mov")
    }

    func testPresentAppliesNormalizationViaTestSeam() {
        MovieSavePanel.presentForTesting = { suggested in
            XCTAssertEqual(suggested, "Output")
            return URL(fileURLWithPath: "/tmp/Output.mp4")
        }

        let url = MovieSavePanel.present(suggestedName: "Output")
        XCTAssertEqual(url?.path, "/tmp/Output.mov")
    }

    func testOpenPanelConfigurationAllowsMultipleMovieSelection() {
        let panel = MovieOpenPanel.makePanel()
        XCTAssertTrue(panel.allowsMultipleSelection)
        XCTAssertTrue(panel.canChooseFiles)
        XCTAssertFalse(panel.canChooseDirectories)
        XCTAssertFalse(panel.allowedContentTypes.isEmpty)
    }

    func testSavePanelConfigurationTargetsQuickTimeMovie() {
        let panel = MovieSavePanel.makePanel(suggestedName: "Clip")
        XCTAssertEqual(panel.allowedContentTypes, [MovieContentTypes.exportType])
        XCTAssertFalse(panel.allowsOtherFileTypes)
        XCTAssertEqual(panel.nameFieldStringValue, "Clip.mov")
    }
}
