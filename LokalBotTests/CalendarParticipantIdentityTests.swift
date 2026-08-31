import XCTest
@testable import LokalBot

final class CalendarParticipantIdentityTests: XCTestCase {
    func testExtractsAndNormalizesMailtoAddress() {
        XCTAssertEqual(
            CalendarParticipantIdentity.emailAddress(
                from: URL(string: "mailto:Ana.Petrovic%2BMeetings@Example.COM?subject=Hello")),
            "ana.petrovic+meetings@example.com")
        XCTAssertNil(CalendarParticipantIdentity.emailAddress(
            from: URL(string: "urn:uuid:participant-123")))
    }

    func testDeduplicatesByEmailAndPrefersAvailableName() throws {
        let emailOnly = try XCTUnwrap(CalendarParticipantIdentity(
            id: "first",
            name: nil,
            emailAddress: "ANA@example.com"))
        let named = try XCTUnwrap(CalendarParticipantIdentity(
            id: "second",
            name: " Ana Petrović ",
            emailAddress: "ana@example.com"))

        let result = CalendarParticipantIdentity.normalized([emailOnly, named])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.id, "first")
        XCTAssertEqual(result.first?.name, "Ana Petrović")
        XCTAssertEqual(result.first?.emailAddress, "ana@example.com")
    }

    func testSameNameWithDifferentEmailsRemainsDistinct() throws {
        let first = try XCTUnwrap(CalendarParticipantIdentity(
            id: "first", name: "Alex Kim", emailAddress: "alex@one.example"))
        let second = try XCTUnwrap(CalendarParticipantIdentity(
            id: "second", name: "Alex Kim", emailAddress: "alex@two.example"))

        XCTAssertEqual(CalendarParticipantIdentity.normalized([first, second]).count, 2)
    }

    func testLegacyNameIdentityIsStableAcrossLoads() {
        let first = CalendarParticipantIdentity.fromLegacyNames(["Ana Petrović"])
        let second = CalendarParticipantIdentity.fromLegacyNames(["Ana Petrović"])

        XCTAssertEqual(first.map(\.id), second.map(\.id))
    }

    func testMeetingMetadataRoundTripsStructuredCalendarIdentities() throws {
        var meeting = Meeting(
            id: UUID(),
            title: "Design review",
            appName: "Zoom",
            startedAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 2_000),
            relativePath: "meetings/2026/08/28-design-review")
        meeting.calendarParticipantIdentities = [try XCTUnwrap(
            CalendarParticipantIdentity(
                id: "fixture-ana",
                name: "Ana Petrović",
                emailAddress: "ana@example.com"))]

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Meeting.self, from: encoder.encode(meeting))

        XCTAssertEqual(decoded.resolvedCalendarParticipantIdentities, [
            try XCTUnwrap(CalendarParticipantIdentity(
                id: "fixture-ana",
                name: "Ana Petrović",
                emailAddress: "ana@example.com")),
        ])
    }
}
