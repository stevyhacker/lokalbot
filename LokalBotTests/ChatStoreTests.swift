import CryptoKit
import XCTest
@testable import LokalBot

/// Persistence for the Chat section's conversation history: the on-disk
/// round-trip through `ChatStore`, that the transient `isPending` flag is never
/// written (while `isError` and tool `activity` are), and that `loadAll`
/// returns conversations most-recently-updated first.
@MainActor
final class ChatStoreTests: XCTestCase {

    private var root: URL!
    private let encryptionKey = SymmetricKey(data: Data(repeating: 0xA5, count: 32))

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testSaveAndLoadRoundTrip() throws {
        let store = makeStore()
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
        let store = makeStore()
        store.save(Conversation(title: "older", updatedAt: Date(timeIntervalSince1970: 1_000),
                                messages: [ChatMessage(role: .user, text: "a")]))
        store.save(Conversation(title: "newer", updatedAt: Date(timeIntervalSince1970: 2_000),
                                messages: [ChatMessage(role: .user, text: "b")]))
        XCTAssertEqual(store.loadAll().map(\.title), ["newer", "older"])
    }

    func testDeleteRemovesConversationFromDisk() {
        let store = makeStore()
        let conversation = Conversation(title: "temp", messages: [ChatMessage(role: .user, text: "x")])
        store.save(conversation)
        XCTAssertEqual(store.loadAll().count, 1)
        store.delete(conversation.id)
        XCTAssertTrue(store.loadAll().isEmpty, "deleting must remove the conversation file")
    }

    func testFilesOnDiskAreEncrypted() throws {
        let store = makeStore()
        store.save(Conversation(title: "Secret pricing strategy",
                                messages: [ChatMessage(role: .user, text: "raise prices 20%")]))

        let chats = root.appendingPathComponent("chats", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: chats, includingPropertiesForKeys: nil)
        let encrypted = files.filter { $0.pathExtension == "enc" }
        XCTAssertEqual(encrypted.count, 1, "conversation should persist as a single sealed .enc file")

        let raw = try Data(contentsOf: try XCTUnwrap(encrypted.first))
        let asText = String(decoding: raw, as: UTF8.self)
        XCTAssertFalse(asText.contains("Secret pricing strategy"), "title must not be readable on disk")
        XCTAssertFalse(asText.contains("raise prices 20%"), "message must not be readable on disk")
        XCTAssertEqual(store.loadAll().first?.title, "Secret pricing strategy", "but it must decrypt back")
    }

    func testLegacyPlaintextIsMigratedToEncrypted() throws {
        let chats = root.appendingPathComponent("chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        let conversation = Conversation(title: "legacy", messages: [ChatMessage(role: .user, text: "old")])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(conversation)
            .write(to: chats.appendingPathComponent("\(conversation.id.uuidString).json"))

        let loaded = makeStore().loadAll()
        XCTAssertEqual(loaded.first?.title, "legacy", "legacy plaintext must still load")

        let files = try FileManager.default.contentsOfDirectory(at: chats, includingPropertiesForKeys: nil)
        XCTAssertTrue(files.contains { $0.pathExtension == "enc" }, "should have migrated to a sealed file")
        XCTAssertFalse(files.contains { $0.lastPathComponent == "\(conversation.id.uuidString).json" },
                       "plaintext must be removed once the sealed copy exists")
    }

    func testChatFailuresUseActionableUserFacingCopy() {
        let download = ChatViewModel.friendlyFailureMessage(
            for: ModelDownloadManager.PreparationError.failed("raw transport details"))
        XCTAssertTrue(download.contains("could not be downloaded"))
        XCTAssertTrue(download.contains("try again"))
        XCTAssertFalse(download.contains("raw transport details"))

        let remote = ChatViewModel.friendlyFailureMessage(
            for: TextEngineError.serverUnreachable("http://127.0.0.1:11434"))
        XCTAssertTrue(remote.contains("could not be reached"))
        XCTAssertFalse(remote.contains("127.0.0.1"))
    }

    private func makeStore() -> ChatStore {
        ChatStore(rootURL: root, encryptionKey: { [encryptionKey] in encryptionKey })
    }
}
