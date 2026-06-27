import XCTest
@testable import LokalBotV3

final class AppSettingsTests: XCTestCase {
    func testDecodesLegacyLanguageHintIntoTypedLanguage() throws {
        let data = #"{"languageHint":"fr"}"#.data(using: .utf8)!

        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(settings.transcriptionLanguage, .fr)
    }

    func testEncodesTypedLanguageWithoutLegacyHintKey() throws {
        var settings = AppSettings()
        settings.transcriptionLanguage = .es

        let data = try JSONEncoder().encode(settings)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["transcriptionLanguage"] as? String, "es")
        XCTAssertNil(object["languageHint"])
    }

    func testMenuBarOnlyDefaultsTrue() {
        XCTAssertTrue(AppSettings().menuBarOnly)
    }

    func testMenuBarOnlyRoundTrips() throws {
        for value in [true, false] {
            var settings = AppSettings()
            settings.menuBarOnly = value
            let data = try JSONEncoder().encode(settings)
            let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
            XCTAssertEqual(decoded.menuBarOnly, value)
        }
    }

    /// Settings persisted by a build that predates the key keep working and
    /// fall back to the menu-bar-only default rather than resetting everything.
    func testDecodesSettingsWithoutMenuBarOnlyKeyAsDefault() throws {
        let data = #"{"autoTranscribe":false}"#.data(using: .utf8)!

        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertTrue(settings.menuBarOnly)
        XCTAssertFalse(settings.autoTranscribe)
    }

    func testLoadAndSaveCanUseInjectedDefaultsSuite() throws {
        let suiteName = "AppSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var saved = AppSettings()
        saved.menuBarOnly = false
        saved.cotypingEnabled = true
        saved.save(to: defaults)

        let loaded = AppSettings.load(from: defaults)

        XCTAssertFalse(loaded.menuBarOnly)
        XCTAssertTrue(loaded.cotypingEnabled)
    }
}
