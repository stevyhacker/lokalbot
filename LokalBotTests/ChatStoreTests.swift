import XCTest
@testable import LokalBotV3

/// Persistence for the Chat section's conversation history: the on-disk
/// round-trip through `ChatStore`, that the transient `isPending` flag is never
/// written (while `isError` and tool `activity` are), and that `loadAll`
/// returns conversations most-recently-updated first.
@MainActor
final class ChatStoreTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testSaveAndLoadRoundTrip() throws {
        let store = ChatStore(rootURL: root)
        let conversation = Conversation(
            title: "Pricing decision",
            messages: [
                ChatMessage(role: .user, text: "What did we decide on pricing?"),
                ChatMessage(role: .assistant, text: "You chose tiered pricing.",
                            activity: [.init(tool: "search_meetings", icon: "magnifyingglass",
                                             text: "Searched meetings", done: true)]),
            ])
        store.save(conversation)

        let loaded = store.loadAll()
        XCTAssertEqual(loaded.count, 1)
        let restored = try XCTUnwrap(loaded.first)
        XCTAssertEqual(restored.id, conversation.id)
        XCTAssertEqual(restored.title, "Pricing decision")
        XCTAssertEqual(restored.messages.map(\.text),
                       ["What did we decide on pricing?", "You chose tiered pricing."])
        XCTAssertEqual(restored.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(restored.messages.last?.activity.first?.tool, "search_meetings",
                       "tool activity chips should survive persistence")
    }

    func testIsPendingIsNeverPersistedButErrorIs() throws {
        let message = ChatMessage(role: .assistant, text: "partial answer",
                                  isPending: true, isError: true)
        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
        XCTAssertFalse(decoded.isPending, "the in-flight flag must not survive a round-trip")
        XCTAssertTrue(decoded.isError, "the error flag must survive a round-trip")
        XCTAssertEqual(decoded.text, "partial answer")
        XCTAssertEqual(decoded.id, message.id, "a message's stable id must survive")
    }

    func testLoadAllSortsByUpdatedAtDescending() {
        let store = ChatStore(rootURL: root)
        store.save(Conversation(title: "older", updatedAt: Date(timeIntervalSince1970: 1_000),
                                messages: [ChatMessage(role: .user, text: "a")]))
        store.save(Conversation(title: "newer", updatedAt: Date(timeIntervalSince1970: 2_000),
                                messages: [ChatMessage(role: .user, text: "b")]))
        XCTAssertEqual(store.loadAll().map(\.title), ["newer", "older"])
    }

    func testDeleteRemovesConversationFromDisk() {
        let store = ChatStore(rootURL: root)
        let conversation = Conversation(title: "temp", messages: [ChatMessage(role: .user, text: "x")])
        store.save(conversation)
        XCTAssertEqual(store.loadAll().count, 1)
        store.delete(conversation.id)
        XCTAssertTrue(store.loadAll().isEmpty, "deleting must remove the conversation file")
    }
}
