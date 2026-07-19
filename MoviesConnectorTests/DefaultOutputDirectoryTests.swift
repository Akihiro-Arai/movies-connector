import XCTest
@testable import MoviesConnector

@MainActor
final class DefaultOutputDirectoryTests: XCTestCase {
    override func tearDown() {
        DefaultOutputDirectory.resetForTesting()
        MoviesOutputAccess.resetForTesting()
        super.tearDown()
    }

    func testManagedDirectoryIsMoviesConnectorUnderMovies() throws {
        let movies = FileManager.default.temporaryDirectory
            .appendingPathComponent("FakeMovies-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: movies, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: movies) }

        DefaultOutputDirectory.moviesDirectoryForTesting = movies

        let managed = try XCTUnwrap(DefaultOutputDirectory.managedDirectoryURL())
        XCTAssertEqual(managed.lastPathComponent, "Movies Connector")
        XCTAssertEqual(managed.deletingLastPathComponent(), movies.standardizedFileURL)

        let file = DefaultOutputDirectory.fileURL(in: managed, fileName: "clip-joined")
        XCTAssertEqual(file.lastPathComponent, "clip-joined.mov")
        XCTAssertTrue(DefaultOutputDirectory.isInsideManagedDirectory(file))
        XCTAssertTrue(DefaultOutputDirectory.isInsideMoviesDirectory(file))
    }

    func testUniqueFileURLAvoidsExistingExport() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UniqueOut-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = DefaultOutputDirectory.uniqueFileURL(in: directory, fileName: "clip-joined.mov")
        XCTAssertEqual(first.lastPathComponent, "clip-joined.mov")
        try Data([0x00]).write(to: first)

        let second = DefaultOutputDirectory.uniqueFileURL(in: directory, fileName: "clip-joined.mov")
        XCTAssertEqual(second.lastPathComponent, "clip-joined-2.mov")
        try Data([0x01]).write(to: second)

        let third = DefaultOutputDirectory.uniqueFileURL(in: directory, fileName: "clip-joined.mov")
        XCTAssertEqual(third.lastPathComponent, "clip-joined-3.mov")
    }

    func testEnsureManagedDirectoryCreatesFolder() throws {
        let movies = FileManager.default.temporaryDirectory
            .appendingPathComponent("FakeMovies-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: movies, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: movies) }

        DefaultOutputDirectory.moviesDirectoryForTesting = movies
        let created = try DefaultOutputDirectory.ensureManagedDirectoryExists()
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.path))
    }

    @MainActor
    func testMoviesOutputAccessAllowCreatesDirectoryAndRemembersGrant() throws {
        let movies = FileManager.default.temporaryDirectory
            .appendingPathComponent("FakeMovies-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: movies, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: movies) }

        DefaultOutputDirectory.moviesDirectoryForTesting = movies
        let defaults = UserDefaults(suiteName: "MoviesConnectorTests.\(UUID().uuidString)")!
        MoviesOutputAccess.defaultsForTesting = defaults
        MoviesOutputAccess.confirmForTesting = { true }

        let directory = try XCTUnwrap(MoviesOutputAccess.requestDefaultDirectoryIfNeeded())
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertTrue(MoviesOutputAccess.hasGrantedAccess)

        MoviesOutputAccess.confirmForTesting = {
            XCTFail("Should not ask again after grant")
            return false
        }
        let again = try XCTUnwrap(MoviesOutputAccess.requestDefaultDirectoryIfNeeded())
        XCTAssertEqual(again.path, directory.path)
    }

    @MainActor
    func testMoviesOutputAccessNotNowLeavesUngranted() {
        MoviesOutputAccess.defaultsForTesting = UserDefaults(
            suiteName: "MoviesConnectorTests.\(UUID().uuidString)"
        )
        MoviesOutputAccess.confirmForTesting = { false }

        XCTAssertNil(MoviesOutputAccess.requestDefaultDirectoryIfNeeded())
        XCTAssertFalse(MoviesOutputAccess.hasGrantedAccess)
    }
}
