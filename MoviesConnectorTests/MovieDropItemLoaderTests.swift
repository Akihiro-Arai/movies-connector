import UniformTypeIdentifiers
import XCTest
@testable import MoviesConnector

final class MovieDropItemLoaderTests: XCTestCase {
    override func tearDown() {
        MovieDropItemLoader.resetForTesting()
        super.tearDown()
    }

    func testPhotosLibraryURLIsRejectedWithoutFallback() async {
        let photos = URL(
            fileURLWithPath: "/Users/me/Pictures/Photos Library.photoslibrary/originals/1/ABC.mov"
        )
        XCTAssertTrue(MovieDropItemLoader.isPhotosLibraryURL(photos))
        XCTAssertFalse(MovieDropItemLoader.shouldUseDirectFileURL(photos))

        MovieDropItemLoader.resolveFileURLForTesting = { _, _ in photos }
        let provider = NSItemProvider()
        let url = await MovieDropItemLoader.loadURL(from: provider)
        XCTAssertNil(url)
    }

    func testReadableFinderURLIsUsedDirectly() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("clip.mov")
        try Data([0x00]).write(to: file)
        XCTAssertTrue(MovieDropItemLoader.shouldUseDirectFileURL(file))
    }

    func testDropAcceptedTypesAreFileURLOnly() {
        let identifiers = MovieDropItemLoader.dropAcceptedTypes.map(\.identifier)
        XCTAssertEqual(identifiers, [UTType.fileURL.identifier])
        XCTAssertEqual(
            MovieDropItemLoader.dropAcceptedTypeIdentifiers,
            [UTType.fileURL.identifier]
        )
    }

    func testLoadResolvesFinderFileURL() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("clip.mov")
        try Data([0x00]).write(to: file)

        MovieDropItemLoader.resolveFileURLForTesting = { _, _ in file }
        let outcome = await MovieDropItemLoader.loadURLsFromCurrentDrop(
            providers: [NSItemProvider()]
        )
        XCTAssertEqual(outcome.urls, [file])
        XCTAssertFalse(outcome.timedOut)
    }

    func testDropLoadTimesOutWhenProviderNeverResponds() async {
        // Simulate Finder never calling back; outer timeout must clear Loading….
        MovieDropItemLoader.dropLoadTimeoutForTesting = 0.25
        MovieDropItemLoader.stallDropLoadForTesting = {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
        }

        let outcome = await MovieDropItemLoader.loadURLsFromCurrentDrop(
            providers: [NSItemProvider()]
        )

        XCTAssertTrue(outcome.urls.isEmpty)
        XCTAssertTrue(outcome.timedOut, outcome.diagnostics.transcript)
        XCTAssertTrue(
            outcome.diagnostics.transcript.contains("TIMEOUT"),
            outcome.diagnostics.transcript
        )
    }
}
