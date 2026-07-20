import XCTest
@testable import MoviesConnector

@MainActor
final class AppLanguageTests: XCTestCase {
    override func tearDown() {
        AppSettings.resetForTesting()
        super.tearDown()
    }

    func testJapaneseLocaleResolvesUIStrings() {
        let defaults = UserDefaults(suiteName: "MoviesConnectorTests.lang.\(UUID().uuidString)")!
        AppLanguageStore.defaultsForTesting = defaults
        AppSettings.shared.language = .japanese

        XCTAssertEqual(AppLanguageStore.effectiveLocale().identifier, "ja")
        XCTAssertEqual(L10n.string("ui.join"), "結合")
        XCTAssertEqual(L10n.string("ui.add_videos"), "動画を追加")
        XCTAssertEqual(L10n.string("settings.language"), "言語")
    }

    func testEnglishLocaleResolvesUIStrings() {
        let defaults = UserDefaults(suiteName: "MoviesConnectorTests.lang.\(UUID().uuidString)")!
        AppLanguageStore.defaultsForTesting = defaults
        AppSettings.shared.language = .english

        XCTAssertEqual(L10n.string("ui.join"), "Join")
        XCTAssertEqual(L10n.string("ui.add_videos"), "Add Videos")
    }

    func testCompatibilityMismatchLocalizesAtPresentationTime() {
        let defaults = UserDefaults(suiteName: "MoviesConnectorTests.lang.\(UUID().uuidString)")!
        AppLanguageStore.defaultsForTesting = defaults

        let mismatch = CompatibilityMismatch.videoDisplaySize("1920x1080", "1280x720")
        AppSettings.shared.language = .english
        XCTAssertEqual(
            mismatch.description,
            "Video display size mismatch (1920x1080 vs 1280x720)"
        )

        AppSettings.shared.language = .japanese
        XCTAssertEqual(
            mismatch.localizedDescription,
            "表示サイズが一致しません（1920x1080 と 1280x720）"
        )
    }

    func testAudioTrackMismatchLocalizesWithTrackIndex() {
        let defaults = UserDefaults(suiteName: "MoviesConnectorTests.lang.\(UUID().uuidString)")!
        AppLanguageStore.defaultsForTesting = defaults

        let mismatch = CompatibilityMismatch.audioCodec(track: 1, "apac", "aac")
        AppSettings.shared.language = .english
        XCTAssertEqual(
            mismatch.description,
            "Audio track[1] codec mismatch (apac vs aac)"
        )

        AppSettings.shared.language = .japanese
        XCTAssertEqual(
            mismatch.localizedDescription,
            "オーディオトラック[1]のコーデックが一致しません（apac と aac）"
        )
    }
}
