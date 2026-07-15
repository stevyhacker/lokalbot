import XCTest
@testable import LokalBot

final class ScreenContextPrivacyTests: XCTestCase {
    func testRedactsCredentialsBeforePersistence() {
        let source = """
        API_KEY=supersecretvalue123
        Authorization: Bearer abcdefghijklmnopqrstuvwxyz
        GitHub ghp_abcdefghijklmnopqrstuvwxyz123456
        OpenAI sk-proj-abcdefghijklmnopqrstuvwxyz123456
        """

        let result = ScreenContextPrivacy.redact(source)

        XCTAssertGreaterThanOrEqual(result.count, 4)
        XCTAssertFalse(result.text.contains("supersecretvalue123"))
        XCTAssertFalse(result.text.contains("abcdefghijklmnopqrstuvwxyz123456"))
        XCTAssertTrue(result.text.contains("[REDACTED"))
    }

    func testPrivateWindowsAndDomainRulesFailClosed() {
        XCTAssertTrue(ScreenContextPrivacy.isPrivateWindow(title: "New Incognito Window"))
        XCTAssertTrue(ScreenContextPrivacy.isPrivateWindow(title: "InPrivate browsing"))
        XCTAssertFalse(ScreenContextPrivacy.isPrivateWindow(title: "Quarterly plan"))

        XCTAssertTrue(ScreenContextPrivacy.isExcluded(
            sourceURL: "https://docs.private.test/report",
            rules: ["*.private.test"]))
        XCTAssertTrue(ScreenContextPrivacy.isExcluded(
            sourceURL: "https://example.com/account/billing",
            rules: ["example.com/account"]))
        XCTAssertFalse(ScreenContextPrivacy.isExcluded(
            sourceURL: "https://example.com.evil.test/account",
            rules: ["example.com"]))
    }

    func testMetadataSanitizationDropsSecretsAndLocalPaths() {
        XCTAssertEqual(
            ScreenContextPrivacy.sanitizedURL(
                "https://alice:password@example.com/private/report?token=secret#section"),
            "https://example.com/private/report")
        XCTAssertEqual(
            ScreenContextPrivacy.sanitizedDocumentName(
                "file:///Users/alice/Private/Launch%20Plan.md"),
            "Launch Plan.md")
    }

    func testRichTextThresholdAvoidsTreatingLabelsAsDocumentContext() {
        XCTAssertFalse(ScreenContextPrivacy.hasRichAccessibleText("Save Cancel Name"))
        XCTAssertTrue(ScreenContextPrivacy.hasRichAccessibleText(String(repeating: "context ", count: 12)))
    }
}
