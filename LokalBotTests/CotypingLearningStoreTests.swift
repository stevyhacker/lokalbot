import AppKit
import CryptoKit
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

final class CotypingAcceptedSuggestionBatchTests: XCTestCase {
    private func field(preceding: String = "Please send") -> CotypingField {
        CotypingField(
            appName: "Mail", bundleID: "com.apple.mail", processID: 1,
            role: "AXTextArea", precedingText: preceding, trailingText: "",
            selectionLength: 0, caretRect: .zero, isSecure: false,
            caretIsExact: true)
    }

    func testAggregatesAcceptedChunksIntoOneLearningRecord() {
        var batch = CotypingAcceptedSuggestionBatch()

        batch.append(field: field(), acceptedText: " the", learningEnabled: true)
        batch.append(field: field(preceding: "Please send the"),
                     acceptedText: " final version", learningEnabled: true)
        let completion = batch.complete()

        XCTAssertEqual(completion?.acceptedChunkCount, 2)
        XCTAssertEqual(completion?.learningRecord?.field.precedingText, "Please send")
        XCTAssertEqual(completion?.learningRecord?.acceptedText, " the final version")
        XCTAssertTrue(batch.isEmpty)
        XCTAssertNil(batch.complete(), "a completed batch must not flush twice")
    }

    func testTracksStatsBoundaryWithoutLearningWhenDisabled() {
        var batch = CotypingAcceptedSuggestionBatch()
        batch.append(field: field(), acceptedText: " this", learningEnabled: false)

        let completion = batch.complete()

        XCTAssertEqual(completion?.acceptedChunkCount, 1)
        XCTAssertNil(completion?.learningRecord)
    }

    func testDiscardLearningPreservesPendingStatsBoundary() {
        var batch = CotypingAcceptedSuggestionBatch()
        batch.append(field: field(), acceptedText: " private text", learningEnabled: true)

        batch.discardLearningRecord()
        let completion = batch.complete()

        XCTAssertEqual(completion?.acceptedChunkCount, 1)
        XCTAssertNil(completion?.learningRecord)
    }
}

final class CotypingLearningStorePersistenceTests: XCTestCase {
    private func field() -> CotypingField {
        CotypingField(
            appName: "Mail", bundleID: "com.apple.mail", processID: 1,
            role: "AXTextArea", precedingText: "Please send", trailingText: "",
            selectionLength: 0, caretRect: .zero, isSecure: false,
            caretIsExact: true)
    }

    @MainActor
    func testCompletedSuggestionQueuesOneSnapshotWrite() async throws {
        let persistence = RecordingCotypingLearningPersistence()
        let store = CotypingLearningStore(
            storageRoot: FileManager.default.temporaryDirectory,
            persistence: persistence,
            initialSnapshot: .init())

        var batch = CotypingAcceptedSuggestionBatch()
        batch.append(field: field(), acceptedText: " the", learningEnabled: true)
        batch.append(field: field(), acceptedText: " final version", learningEnabled: true)
        let completion = try XCTUnwrap(batch.complete())
        let record = try XCTUnwrap(completion.learningRecord)
        store.recordCompletedSuggestion(field: record.field, acceptedText: record.acceptedText)
        await store.waitForPendingPersistence()

        let snapshots = await persistence.recordedSnapshots()
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots[0].examples.count, 1)
        XCTAssertEqual(snapshots[0].examples[0].acceptedText, "the final version")
        XCTAssertEqual(store.exampleCount, 1)
    }

    @MainActor
    func testTerminationFlushWaitsForQueuedLearningWrite() async {
        let persistence = RecordingCotypingLearningPersistence()
        let store = CotypingLearningStore(
            storageRoot: FileManager.default.temporaryDirectory,
            persistence: persistence,
            initialSnapshot: .init())
        store.recordCompletedSuggestion(field: field(), acceptedText: "the final version")

        await store.flushPersistence()

        let snapshots = await persistence.recordedSnapshots()
        XCTAssertEqual(snapshots.count, 1)
    }

    func testEncryptedPersistenceKeepsLegacyCombinedAESGCMFormat() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cotyping-learning-codec-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent("cotyping-learning.enc")
        defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256)
        let snapshot = CotypingLearningSnapshot(examples: [
            CotypingLearningExample(
                id: UUID(), createdAt: Date(timeIntervalSince1970: 123),
                appName: "Mail", bundleID: "com.apple.mail", surfaceClass: "email",
                contextHint: "Q3 planning", prefixTail: "Please send",
                acceptedText: "the final version"),
        ])
        let persistence = EncryptedCotypingLearningPersistence(url: url, key: key)

        await persistence.persist(snapshot)

        let encrypted = try Data(contentsOf: url)
        let sealed = try AES.GCM.SealedBox(combined: encrypted)
        let plaintext = try AES.GCM.open(sealed, using: key)
        XCTAssertEqual(try JSONDecoder().decode(CotypingLearningSnapshot.self, from: plaintext), snapshot)
    }
}

private actor RecordingCotypingLearningPersistence: CotypingLearningPersisting {
    private var snapshots: [CotypingLearningSnapshot] = []
    private var removeCount = 0

    func persist(_ snapshot: CotypingLearningSnapshot) {
        snapshots.append(snapshot)
    }

    func remove() {
        removeCount += 1
    }

    func recordedSnapshots() -> [CotypingLearningSnapshot] { snapshots }
}
