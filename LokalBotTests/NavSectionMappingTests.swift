import XCTest
@testable import LokalBot

/// The NavSection migration mapping (spec §2.1): capture names from the
/// UI-test host env and deep links resolve to sections, with legacy
/// pre-merge names mapping onto the merged Type pillar.
final class NavSectionMappingTests: XCTestCase {

    func testCaptureNamesMapToTheirSections() {
        XCTAssertEqual(AppState.NavSection(captureName: "meetings"), .meetings)
        XCTAssertEqual(AppState.NavSection(captureName: "Timeline"), .timeline)
        XCTAssertEqual(AppState.NavSection(captureName: "type"), .type)
        XCTAssertEqual(AppState.NavSection(captureName: "chat"), .chat)
        XCTAssertEqual(AppState.NavSection(captureName: "search"), .search)
        XCTAssertEqual(AppState.NavSection(captureName: "models"), .models)
        XCTAssertEqual(AppState.NavSection(captureName: "settings"), .settings)
    }

    func testLegacyTypeNamesMapToType() {
        XCTAssertEqual(AppState.NavSection(captureName: "dictation"), .type)
        XCTAssertEqual(AppState.NavSection(captureName: "Cotyping"), .type)
    }

    func testUnknownNameIsNil() {
        XCTAssertNil(AppState.NavSection(captureName: "bogus"))
        XCTAssertNil(AppState.NavSection(captureName: ""))
    }

    func testTypeTabCaptureNamesSelectTheTab() {
        XCTAssertEqual(AppState.TypeTab(captureName: "dictation"), .dictation)
        XCTAssertEqual(AppState.TypeTab(captureName: "Cotyping"), .cotyping)
        XCTAssertNil(AppState.TypeTab(captureName: "type"))
        XCTAssertNil(AppState.TypeTab(captureName: "meetings"))
    }
}
