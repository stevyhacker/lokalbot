import AppKit
import XCTest
@testable import LokalBot

@MainActor
final class CalendarCandidateButtonTests: XCTestCase {
    func testRepresentableContainerVendsOneNativeButtonAndInvokesSelection() {
        let container = CalendarCandidateButtonContainer()
        var selected = false
        container.update(
            title: "Ana Petrović, ana@example.com",
            systemImageName: "person.crop.circle",
            accessibilityIdentifier: "speaker.rename.calendarCandidate.0",
            isSelected: false,
            isEnabled: true,
            action: { selected = true })

        let button = container.button
        XCTAssertFalse(container.isAccessibilityElement())
        XCTAssertEqual(container.accessibilityChildren()?.count, 1)
        XCTAssertTrue(container.accessibilityChildren()?.first as? NSButton === button)
        XCTAssertTrue(button.isAccessibilityElement())
        XCTAssertEqual(button.accessibilityRole(), .button)
        XCTAssertEqual(
            button.accessibilityIdentifier(),
            "speaker.rename.calendarCandidate.0")
        XCTAssertEqual(button.accessibilityLabel(), "Ana Petrović, ana@example.com")

        button.performClick(nil)
        XCTAssertTrue(selected)
    }
}
