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
        XCTAssertTrue(settings.dictationLivePreview)
        XCTAssertFalse(settings.dictationRetainAudio)
    }

    func testSpeechDefaultsUseKokoroHeartAtNormalSpeed() {
        let settings = AppSettings()

        XCTAssertEqual(settings.speechVoice, .heart)
        XCTAssertEqual(settings.speechSpeed, 1.0)
    }

    func testSpeechSettingsRoundTripAndClampSpeed() throws {
        var settings = AppSettings()
        settings.speechVoice = .fable
        settings.speechSpeed = 3.5

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(decoded.speechVoice, .fable)
        XCTAssertEqual(decoded.speechSpeed, AppSettings.maximumSpeechSpeed)
    }

    /// Settings written before TranscriptionModelChoice raw values were
    /// stabilized persisted the display strings — they must keep decoding so
    /// an update never silently resets a user's model choice.
    func testDecodesLegacyTranscriptionModelDisplayString() throws {
        let data = #"{"transcriptionModel":"Parakeet TDT 0.6B v3 (multilingual)"}"#.data(using: .utf8)!

        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(settings.transcriptionModel, .parakeetV3)
    }

    func testTranscriptionModelPersistsStableRawValue() throws {
        var settings = AppSettings()
        settings.transcriptionModel = .whisperLarge

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertTrue(String(data: data, encoding: .utf8)!.contains("whisper-large-v3-turbo"))
        XCTAssertEqual(decoded.transcriptionModel, .whisperLarge)
    }

    func testUnknownTranscriptionModelFallsBackToDefault() throws {
        let data = #"{"transcriptionModel":"some-future-model"}"#.data(using: .utf8)!

        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(settings.transcriptionModel, TranscriptionModelChoice.recommended)
    }

    /// Day memory is strictly opt-in: neither activity tracking nor screen
    /// capture may ever default on — accepting onboarding must not silently
    /// start watching the screen.
    func testDayTrackingAndScreenshotsDefaultOff() {
        XCTAssertFalse(AppSettings().trackingEnabled)
        XCTAssertFalse(AppSettings().screenshotsEnabled)
    }

    /// A settings blob saved by an existing install keeps whatever the user
    /// had — the new opt-in default only applies to fresh installs.
    func testExistingScreenshotChoiceSurvivesDefaultFlip() throws {
        let data = #"{"trackingEnabled":true,"screenshotsEnabled":true}"#.data(using: .utf8)!

        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertTrue(settings.trackingEnabled)
        XCTAssertTrue(settings.screenshotsEnabled)
    }

    /// The default prunes OCR text on the same schedule as the pixels;
    /// keeping it forever is the explicit opt-in.
    func testKeepOCRTextForeverDefaultsFalse() {
        XCTAssertFalse(AppSettings().keepOCRTextForever)
    }

    func testDecodesSettingsWithoutKeepOCRTextForeverKeyAsDefault() throws {
        let data = #"{"autoTranscribe":false}"#.data(using: .utf8)!

        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertFalse(settings.keepOCRTextForever)
        XCTAssertFalse(settings.autoTranscribe)
    }

    func testKeepOCRTextForeverRoundTrips() throws {
        var settings = AppSettings()
        settings.keepOCRTextForever = true

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertTrue(decoded.keepOCRTextForever)
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
        settings.dictationLivePreview = false
        settings.dictationRetainAudio = true

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertTrue(decoded.dictationEnabled)
        XCTAssertEqual(decoded.dictationTriggerMode, .toggle)
        XCTAssertEqual(decoded.dictationOutputMode, .copyToClipboard)
        XCTAssertFalse(decoded.dictationShowOverlay)
        XCTAssertFalse(decoded.dictationLivePreview)
        XCTAssertTrue(decoded.dictationRetainAudio)
    }

    func testDecodesSettingsWithoutDictationLivePreviewKeyAsDefault() throws {
        let data = #"{"autoTranscribe":false}"#.data(using: .utf8)!

        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertTrue(settings.dictationLivePreview)
        XCTAssertFalse(settings.autoTranscribe)
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
