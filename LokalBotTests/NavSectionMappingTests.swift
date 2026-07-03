import XCTest
@testable import LokalBot

/// The NavSection migration mapping (spec §2.1): capture names from the
/// UI-test host env and deep links resolve to sections, with legacy
/// pre-merge names mapping onto the merged pillars.
final class NavSectionMappingTests: XCTestCase {

    func testCaptureNamesMapToTheirSections() {
        XCTAssertEqual(AppState.NavSection(captureName: "capture"), .capture)
        XCTAssertEqual(AppState.NavSection(captureName: "type"), .type)
        XCTAssertEqual(AppState.NavSection(captureName: "ask"), .ask)
        XCTAssertEqual(AppState.NavSection(captureName: "settings"), .settings)
    }

    /// Spec §2.5: Settings absorbs Models — the legacy "models" capture name
    /// lands on Settings, and the SettingsTab mapping preselects its tab.
    func testLegacyModelsNameMapsToSettings() {
        XCTAssertEqual(AppState.NavSection(captureName: "models"), .settings)
        XCTAssertEqual(AppState.NavSection(captureName: "Models"), .settings)
    }

    func testSettingsTabCaptureNamesSelectTheTab() {
        XCTAssertEqual(AppState.SettingsTab(captureName: "models"), .models)
        XCTAssertEqual(AppState.SettingsTab(captureName: "general"), .general)
        XCTAssertEqual(AppState.SettingsTab(captureName: "recording"), .recording)
        XCTAssertEqual(AppState.SettingsTab(captureName: "privacy"), .privacy)
        XCTAssertEqual(AppState.SettingsTab(captureName: "advanced"), .advanced)
        XCTAssertNil(AppState.SettingsTab(captureName: "settings"))
        XCTAssertNil(AppState.SettingsTab(captureName: "capture"))
    }

    func testLegacyMeetingsAndTimelineNamesMapToCapture() {
        XCTAssertEqual(AppState.NavSection(captureName: "meetings"), .capture)
        XCTAssertEqual(AppState.NavSection(captureName: "Timeline"), .capture)
    }

    func testLegacyTypeNamesMapToType() {
        XCTAssertEqual(AppState.NavSection(captureName: "dictation"), .type)
        XCTAssertEqual(AppState.NavSection(captureName: "Cotyping"), .type)
    }

    func testLegacySearchAndChatNamesMapToAsk() {
        XCTAssertEqual(AppState.NavSection(captureName: "search"), .ask)
        XCTAssertEqual(AppState.NavSection(captureName: "chat"), .ask)
        XCTAssertEqual(AppState.NavSection(captureName: "Search"), .ask)
    }

    func testUnknownNameIsNil() {
        XCTAssertNil(AppState.NavSection(captureName: "bogus"))
        XCTAssertNil(AppState.NavSection(captureName: ""))
    }

    func testTypeTabCaptureNamesSelectTheTab() {
        XCTAssertEqual(AppState.TypeTab(captureName: "dictation"), .dictation)
        XCTAssertEqual(AppState.TypeTab(captureName: "Cotyping"), .cotyping)
        XCTAssertNil(AppState.TypeTab(captureName: "type"))
        XCTAssertNil(AppState.TypeTab(captureName: "capture"))
    }
}
