import XCTest
@testable import LokalBot

final class LeaseBookTests: XCTestCase {

    func testRoleVocabularyMatchesLlamaServerTrio() {
        XCTAssertEqual(InferenceRole.mainLLM.serverPort, 17872)
        XCTAssertEqual(InferenceRole.embedder.serverPort, 17873)
        XCTAssertEqual(InferenceRole.cotypingServer.serverPort, 17874)
        XCTAssertEqual(InferenceRole.mainLLM.residencyID, "llama-server:17872")
        XCTAssertEqual(InferenceRole(serverPort: 17873), .embedder)
        XCTAssertNil(InferenceRole(serverPort: 17875))
        XCTAssertTrue(InferencePriority.interactive < .agent)
        XCTAssertTrue(InferencePriority.agent < .background)
        XCTAssertEqual(InferencePriority.interactive.label, "interactive")
        XCTAssertEqual(InferenceRole.mainLLM.defaultLingerSeconds, 600)
        XCTAssertEqual(InferenceRole.embedder.defaultLingerSeconds, 600)
        XCTAssertEqual(InferenceRole.cotypingServer.defaultLingerSeconds, 900)
    }

    func testAcquireAndReleaseTrackCountsPerRole() {
        var book = LeaseBook()
        let chat = book.acquire(role: .mainLLM, priority: .interactive, purpose: "chat")
        let summary = book.acquire(role: .mainLLM, priority: .background, purpose: "summary")
        _ = book.acquire(role: .embedder, priority: .background, purpose: "embeddings")

        XCTAssertNotEqual(chat.id, summary.id)
        XCTAssertEqual(book.activeCount(for: .mainLLM), 2)
        XCTAssertEqual(book.activeCount(for: .embedder), 1)
        XCTAssertEqual(book.activeCount(for: .cotypingServer), 0)

        XCTAssertTrue(book.release(id: chat.id))
        XCTAssertEqual(book.activeCount(for: .mainLLM), 1)
        XCTAssertFalse(book.release(id: chat.id), "double release must be a no-op")
    }

    func testPinnedResidencyIDsCoverEveryOpenLease() {
        var book = LeaseBook()
        XCTAssertTrue(book.pinnedResidencyIDs.isEmpty)
        let chat = book.acquire(role: .mainLLM, priority: .interactive, purpose: "chat")
        _ = book.acquire(role: .embedder, priority: .background, purpose: "embeddings")
        XCTAssertEqual(book.pinnedResidencyIDs, ["llama-server:17872", "llama-server:17873"])
        book.release(id: chat.id)
        XCTAssertEqual(book.pinnedResidencyIDs, ["llama-server:17873"])
    }

    func testDescriptionsOrderedByPriorityThenPurpose() {
        var book = LeaseBook()
        _ = book.acquire(role: .mainLLM, priority: .background, purpose: "summary")
        _ = book.acquire(role: .mainLLM, priority: .interactive, purpose: "chat")
        _ = book.acquire(role: .embedder, priority: .background, purpose: "embeddings")

        XCTAssertEqual(book.descriptionsByResidencyID, [
            "llama-server:17872": ["chat (interactive)", "summary (background)"],
            "llama-server:17873": ["embeddings (background)"],
        ])
    }

    func testRecordKeepsExpiry() {
        var book = LeaseBook()
        let deadline = Date(timeIntervalSince1970: 1_000_000)
        let ttl = book.acquire(role: .mainLLM, priority: .agent, purpose: "ask_library",
                               expiresAt: deadline)
        let open = book.acquire(role: .mainLLM, priority: .interactive, purpose: "chat")
        XCTAssertEqual(book.record(id: ttl.id)?.expiresAt, deadline)
        XCTAssertNotNil(book.record(id: open.id))
        XCTAssertNil(book.record(id: open.id)?.expiresAt)
        book.release(id: ttl.id)
        XCTAssertNil(book.record(id: ttl.id))
    }
}
