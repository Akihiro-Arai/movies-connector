import XCTest
import UniformTypeIdentifiers
@testable import MoviesConnector

final class MovieContentTypesTests: XCTestCase {
    func testRejectsKnownNonMovieTypeEvenWhenExtensionLooksLikeMovie() {
        let url = URL(fileURLWithPath: "/Movies/notes.mov")
        XCTAssertFalse(
            MovieContentTypes.isSupportedMovie(
                url: url,
                typeIdentifier: UTType.plainText.identifier
            )
        )
    }

    func testAcceptsMovieTypeIdentifier() {
        let url = URL(fileURLWithPath: "/Movies/clip.mov")
        XCTAssertTrue(
            MovieContentTypes.isSupportedMovie(
                url: url,
                typeIdentifier: UTType.quickTimeMovie.identifier
            )
        )
    }

    func testExtensionFallbackOnlyWhenTypeIdentifierMissingOrUnresolved() {
        let url = URL(fileURLWithPath: "/Movies/clip.mp4")
        XCTAssertTrue(MovieContentTypes.isSupportedMovie(url: url, typeIdentifier: nil))
        XCTAssertTrue(
            MovieContentTypes.isSupportedMovie(
                url: url,
                typeIdentifier: "not.a.real.type.identifier.xyz"
            )
        )
        XCTAssertFalse(
            MovieContentTypes.isSupportedMovie(
                url: URL(fileURLWithPath: "/Movies/notes.txt"),
                typeIdentifier: nil
            )
        )
    }
}
