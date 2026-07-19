import UniformTypeIdentifiers
import XCTest
@testable import MoviesConnector

final class MovieDropItemLoaderTests: XCTestCase {
    override func tearDown() {
        MovieDropItemLoader.resetForTesting()
        super.tearDown()
    }

    func testPhotosLibraryURLIsNotUsedDirectly() {
        let photos = URL(
            fileURLWithPath: "/Users/me/Pictures/Photos Library.photoslibrary/originals/1/ABC.mov"
        )
        XCTAssertTrue(MovieDropItemLoader.isPhotosLibraryURL(photos))
        XCTAssertFalse(MovieDropItemLoader.shouldUseDirectFileURL(photos))
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

    func testLoadFallsBackToRepresentationForPhotosLibraryFileURL() async {
        let photos = URL(
            fileURLWithPath: "/Users/me/Pictures/Photos Library.photoslibrary/originals/1/ABC.mov"
        )
        let materialized = FileManager.default.temporaryDirectory
            .appendingPathComponent("photos-drop-\(UUID().uuidString).mov")

        MovieDropItemLoader.resolveFileURLForTesting = { _, _ in photos }
        MovieDropItemLoader.resolveRepresentationForTesting = { _ in materialized }

        let provider = NSItemProvider()
        let url = await MovieDropItemLoader.loadURL(from: provider)
        XCTAssertEqual(url, materialized)
    }

    func testLoadPrefersSnapshottedFilePromises() async {
        let promised = FileManager.default.temporaryDirectory
            .appendingPathComponent("promise-\(UUID().uuidString).mov")
        MovieDropItemLoader.resolveFilePromisesForTesting = { [promised] }
        MovieDropItemLoader.resolveRepresentationForTesting = { _ in
            XCTFail("Should not fall back when promises resolve")
            return nil
        }

        let outcome = await MovieDropItemLoader.loadURLsFromCurrentDrop(
            providers: [NSItemProvider()],
            promiseReceivers: []
        )
        XCTAssertEqual(outcome.urls, [promised])
        XCTAssertFalse(outcome.diagnostics.transcript.isEmpty)
    }

    func testPersistDropCopyCreatesIndependentFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("source.mov")
        let payload = Data("movie-bytes".utf8)
        try payload.write(to: source)

        let copied = try MovieDropItemLoader.persistDropCopy(of: source)
        defer { try? FileManager.default.removeItem(at: copied) }

        XCTAssertNotEqual(copied, source)
        XCTAssertEqual(try Data(contentsOf: copied), payload)
        XCTAssertEqual(copied.pathExtension.lowercased(), "mov")
        XCTAssertTrue(copied.lastPathComponent.contains("source.mov"))
    }

    func testDropAcceptedTypesIncludeFileURLAndMovie() {
        let identifiers = Set(MovieDropItemLoader.dropAcceptedTypes.map(\.identifier))
        XCTAssertTrue(identifiers.contains(UTType.fileURL.identifier))
        XCTAssertTrue(identifiers.contains(UTType.movie.identifier))
        XCTAssertTrue(identifiers.contains(UTType.audiovisualContent.identifier))
    }

    func testPersistDropCopyUsesIsolatedSessionDirectory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("source.mov")
        try Data("movie-bytes".utf8).write(to: source)

        let sessionA = try MovieDropItemLoader.makeDropSessionDirectory()
        let sessionB = try MovieDropItemLoader.makeDropSessionDirectory()
        defer {
            try? FileManager.default.removeItem(at: sessionA)
            try? FileManager.default.removeItem(at: sessionB)
        }

        let copyA = try MovieDropItemLoader.persistDropCopy(of: source, in: sessionA)
        let copyB = try MovieDropItemLoader.persistDropCopy(of: source, in: sessionB)
        XCTAssertTrue(copyA.path.hasPrefix(sessionA.path))
        XCTAssertTrue(copyB.path.hasPrefix(sessionB.path))
        XCTAssertTrue(MovieDropItemLoader.isOwnedDropCopy(copyA))
        XCTAssertFalse(MovieDropItemLoader.isOwnedDropCopy(source))
    }

    func testCleanupAbandonedDropSessionsRemovesOldFolders() throws {
        let session = try MovieDropItemLoader.makeDropSessionDirectory()
        let marker = session.appendingPathComponent("old.mov")
        try Data([0x01]).write(to: marker)

        let past = Date().addingTimeInterval(-7200)
        try FileManager.default.setAttributes(
            [.modificationDate: past],
            ofItemAtPath: session.path
        )

        MovieDropItemLoader.cleanupAbandonedDropSessions(olderThan: 3600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.path))
    }
}
