import XCTest
@testable import MoviesConnector

final class DroppedMovieURLFilterTests: XCTestCase {
    override func tearDown() {
        DroppedMovieURLFilter.resetForTesting()
        super.tearDown()
    }

    func testAcceptsMovieFilesPreservesOrderAndAllowsDuplicates() {
        let a = URL(fileURLWithPath: "/Movies/a.mov")
        let b = URL(fileURLWithPath: "/Movies/b.mp4")
        let again = URL(fileURLWithPath: "/Movies/a.mov")

        DroppedMovieURLFilter.resourceInfoForTesting = { url in
            DroppedMovieURLFilter.ResourceInfo(
                isRegularFile: true,
                typeIdentifier: url.pathExtension.lowercased() == "mp4"
                    ? "public.mpeg-4"
                    : "com.apple.quicktime-movie"
            )
        }

        let result = DroppedMovieURLFilter.filter([a, b, again])
        XCTAssertEqual(result.accepted, [a, b, again])
        XCTAssertTrue(result.rejected.isEmpty)
    }

    func testRejectsNonFileURLDirectoriesAndUnsupportedTypesWithReasons() {
        let remote = URL(string: "https://example.com/clip.mov")!
        let folder = URL(fileURLWithPath: "/Movies/Album", isDirectory: true)
        let text = URL(fileURLWithPath: "/Movies/notes.txt")
        let movie = URL(fileURLWithPath: "/Movies/ok.m4v")

        DroppedMovieURLFilter.resourceInfoForTesting = { url in
            if url == folder {
                return DroppedMovieURLFilter.ResourceInfo(isRegularFile: false, typeIdentifier: "public.folder")
            }
            if url == text {
                return DroppedMovieURLFilter.ResourceInfo(isRegularFile: true, typeIdentifier: "public.plain-text")
            }
            if url == movie {
                return DroppedMovieURLFilter.ResourceInfo(isRegularFile: true, typeIdentifier: "public.mpeg-4")
            }
            return nil
        }

        let result = DroppedMovieURLFilter.filter([remote, folder, text, movie])
        XCTAssertEqual(result.accepted, [movie])
        XCTAssertEqual(result.rejected.map(\.url), [remote, folder, text])
        XCTAssertEqual(result.rejected.map(\.reason), [
            .notAFileURL,
            .notAFile,
            .unsupportedType,
        ])
        XCTAssertNotNil(result.rejected[0].reason.errorDescription)
        XCTAssertNotNil(result.rejected[1].reason.errorDescription)
        XCTAssertNotNil(result.rejected[2].reason.errorDescription)
    }

    func testMissingResourceInfoIsRejectedAsNotAFile() {
        let url = URL(fileURLWithPath: "/Movies/ghost.mov")
        DroppedMovieURLFilter.resourceInfoForTesting = { _ in nil }

        let result = DroppedMovieURLFilter.filter([url])
        XCTAssertTrue(result.accepted.isEmpty)
        XCTAssertEqual(result.rejected, [
            DroppedMovieURLFilter.Rejection(url: url, reason: .notAFile),
        ])
    }

    func testRejectsPlainTextEvenWhenPathExtensionLooksLikeMovie() {
        let disguised = URL(fileURLWithPath: "/Movies/notes.mov")

        DroppedMovieURLFilter.resourceInfoForTesting = { _ in
            DroppedMovieURLFilter.ResourceInfo(
                isRegularFile: true,
                typeIdentifier: "public.plain-text"
            )
        }

        let result = DroppedMovieURLFilter.filter([disguised])
        XCTAssertTrue(result.accepted.isEmpty)
        XCTAssertEqual(result.rejected, [
            DroppedMovieURLFilter.Rejection(url: disguised, reason: .unsupportedType),
        ])
    }
}
