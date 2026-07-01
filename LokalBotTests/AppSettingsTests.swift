import XCTest
@testable import LokalBot

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

    func testMultiSpeakerDiarizationDefaultsTrue() {
        XCTAssertTrue(AppSettings().multiSpeakerDiarization)
    }

    func testDictationDefaultsMatchHandyStyleShortcutFlow() {
        let settings = AppSettings()

        XCTAssertFalse(settings.dictationEnabled)
        XCTAssertEqual(settings.dictationTriggerMode, .pushToTalk)
        XCTAssertEqual(settings.dictationOutputMode, .pasteIntoFocusedApp)
        XCTAssertTrue(settings.dictationShowOverlay)
        XCTAssertFalse(settings.dictationRetainAudio)
    }

    func testStopDebounceDefaultsToBackToBackFriendlyValue() {
        XCTAssertEqual(AppSettings().stopDebounceSeconds, AppSettings.defaultStopDebounceSeconds)
    }

    func testMigratesLegacyStopDebounceDefault() throws {
        let data = #"{"stopDebounceSeconds":60}"#.data(using: .utf8)!

        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(settings.stopDebounceSeconds, AppSettings.defaultStopDebounceSeconds)
    }

    func testPreservesExplicitCurrentStopDebounceValue() throws {
        let data = #"{"meetingSettingsVersion":1,"stopDebounceSeconds":60}"#.data(using: .utf8)!

        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(settings.stopDebounceSeconds, 60)
    }

    func testDecodesSettingsWithoutMultiSpeakerDiarizationKeyAsDefault() throws {
        let data = #"{"autoTranscribe":false}"#.data(using: .utf8)!

        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertTrue(settings.multiSpeakerDiarization)
        XCTAssertFalse(settings.autoTranscribe)
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

    func testDictationSettingsRoundTrip() throws {
        var settings = AppSettings()
        settings.dictationEnabled = true
        settings.dictationTriggerMode = .toggle
        settings.dictationOutputMode = .copyToClipboard
        settings.dictationShowOverlay = false
        settings.dictationRetainAudio = true

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertTrue(decoded.dictationEnabled)
        XCTAssertEqual(decoded.dictationTriggerMode, .toggle)
        XCTAssertEqual(decoded.dictationOutputMode, .copyToClipboard)
        XCTAssertFalse(decoded.dictationShowOverlay)
        XCTAssertTrue(decoded.dictationRetainAudio)
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
