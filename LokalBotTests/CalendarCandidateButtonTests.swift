import AppKit
import XCTest
@testable import LokalBot

@MainActor
final class CalendarCandidateButtonTests: XCTestCase {
    func testNativeControlExposesOneButtonAndInvokesSelection() {
        let button = CalendarCandidateButtonControl()
        var selected = false
        button.update(
            title: "Ana Petrović, ana@example.com",
            systemImageName: "person.crop.circle",
            accessibilityIdentifier: "speaker.rename.calendarCandidate.0",
            isSelected: false,
            isEnabled: true,
            action: { selected = true })

        XCTAssertEqual(button.accessibilityRole(), .button)
        XCTAssertEqual(
            button.accessibilityIdentifier(),
            "speaker.rename.calendarCandidate.0")
        XCTAssertEqual(button.accessibilityLabel(), "Ana Petrović, ana@example.com")

        button.performClick(nil)
        XCTAssertTrue(selected)
    }
}
