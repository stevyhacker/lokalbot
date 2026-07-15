import AppKit
import XCTest
@testable import LokalBot

// MARK: - Local learning

final class CotypingLearningRankerTests: XCTestCase {
    private func field(
        preceding: String,
        appName: String = "Mail",
        bundleID: String? = "com.apple.mail",
        windowTitle: String? = nil
    ) -> CotypingField {
        CotypingField(
            appName: appName, bundleID: bundleID, processID: 1, role: "AXTextArea",
            precedingText: preceding, trailingText: "", selectionLength: 0,
            caretRect: .zero, isSecure: false, caretIsExact: true,
            windowTitle: windowTitle)
    }

    func testSanitizesAcceptedText() {
        XCTAssertEqual(
            CotypingLearningRanker.acceptedText("  thanks\u{0000}\nagain  "),
            "thanks again")
        XCTAssertNil(CotypingLearningRanker.acceptedText("ok"))
    }

    func testDoesNotLearnPromptScaffolding() {
        XCTAssertNil(CotypingLearningRanker.acceptedText("On the clipboard: secret release plan"))
        XCTAssertNil(CotypingLearningRanker.acceptedText("Previously accepted completion: send it tomorrow"))
        XCTAssertNil(CotypingLearningRanker.acceptedText("System prompt: continue the user's text"))
    }

    func testDoesNotLearnInSecureFieldsOrTerminals() {
        var secure = field(preceding: "password")
        secure.isSecure = true
        XCTAssertFalse(CotypingLearningRanker.canLearn(from: secure))
        XCTAssertFalse(CotypingLearningRanker.canLearn(from: field(
            preceding: "ls",
            appName: "Terminal",
            bundleID: "com.apple.Terminal")))
    }

    func testRankingPrefersSameBundleAndPrefixOverlap() {
        let now = Date()
        let examples = [
            CotypingLearningExample(
                id: UUID(), createdAt: now.addingTimeInterval(-30),
                appName: "Slack", bundleID: "com.tinyspeck.slackmacgap",
                surfaceClass: "chat", contextHint: nil,
                prefixTail: "quick follow up from yesterday",
                acceptedText: "sounds good to me"),
            CotypingLearningExample(
                id: UUID(), createdAt: now.addingTimeInterval(-60),
                appName: "Mail", bundleID: "com.apple.mail",
                surfaceClass: "email", contextHint: nil,
                prefixTail: "quick follow up on the contract",
                acceptedText: "I can send the final version today"),
        ]

        let ranked = CotypingLearningRanker.rankedExamples(
            examples,
            for: field(preceding: "quick follow up"),
            limit: 1)

        XCTAssertEqual(ranked, ["I can send the final version today"])
    }

    func testRankingDropsWeaklyRelatedExamples() {
        let examples = [
            CotypingLearningExample(
                id: UUID(), createdAt: Date(),
                appName: "Slack", bundleID: "com.tinyspeck.slackmacgap",
                surfaceClass: "chat", contextHint: nil,
                prefixTail: "unrelated thread about dinner",
                acceptedText: "sounds good to me"),
        ]

        let ranked = CotypingLearningRanker.rankedExamples(
            examples,
            for: field(preceding: "quick follow up"),
            limit: 1)

        XCTAssertEqual(ranked, [])
    }

    func testRankingQuarantinesPreviouslyPersistedPromptLeak() {
        let examples = [
            CotypingLearningExample(
                id: UUID(), createdAt: Date(),
                appName: "Mail", bundleID: "com.apple.mail",
                surfaceClass: "email", contextHint: nil,
                prefixTail: "quick follow up",
                acceptedText: "On the clipboard: secret release plan"),
            CotypingLearningExample(
                id: UUID(), createdAt: Date().addingTimeInterval(-1),
                appName: "Mail", bundleID: "com.apple.mail",
                surfaceClass: "email", contextHint: nil,
                prefixTail: "quick follow up",
                acceptedText: "I can send the final version today"),
        ]

        let ranked = CotypingLearningRanker.rankedExamples(
            examples,
            for: field(preceding: "quick follow up"),
            limit: 2)

        XCTAssertEqual(ranked, ["I can send the final version today"])
    }

    func testRankingUsesContextAndDeduplicates() {
        let now = Date()
        let examples = [
            CotypingLearningExample(
                id: UUID(), createdAt: now.addingTimeInterval(-10),
                appName: "Mail", bundleID: "com.apple.mail",
                surfaceClass: "email", contextHint: nil,
                prefixTail: "quick follow up",
                acceptedText: "I can send the final version today"),
            CotypingLearningExample(
                id: UUID(), createdAt: now.addingTimeInterval(-20),
                appName: "Mail", bundleID: "com.apple.mail",
                surfaceClass: "email",
                contextHint: "An email being written in Mail. The window is titled \"Q3 planning\".",
                prefixTail: "quick follow up",
                acceptedText: "I can send the final version today"),
            CotypingLearningExample(
                id: UUID(), createdAt: now.addingTimeInterval(-30),
                appName: "Mail", bundleID: "com.apple.mail",
                surfaceClass: "email",
                contextHint: "An email being written in Mail. The window is titled \"Q3 planning\".",
                prefixTail: "quick follow up",
                acceptedText: "I will follow up on the Q3 planning notes"),
        ]

        let ranked = CotypingLearningRanker.rankedExamples(
            examples,
            for: field(preceding: "quick follow up", windowTitle: "Q3 planning"),
            limit: 3)

        XCTAssertEqual(ranked.first, "I can send the final version today")
        XCTAssertEqual(ranked.count, 2)
    }
}
