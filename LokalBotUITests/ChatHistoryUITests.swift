import XCTest

/// The Chat section surfaces persisted conversation history. A conversation
/// seeded on disk (under `<root>/chats/`) before launch must appear in the
/// conversation-list column and open its messages in the transcript — proving
/// `ChatStore` load + the three-column chat wiring end to end, without ever
/// touching the local LLM.
///
/// Its own `setUp` (separate from `MainWindowUITests`) plants a chat-seeded
/// root, so the shared empty-state chat test stays unaffected.
final class ChatHistoryUITests: XCTestCase {

    private var root: URL!
    private var app: XCUIApplication!
    private var defaultsSuiteName: String?

    private let conversationTitle = "Pricing decision"
    private let assistantLine = "You chose tiered pricing."

    override func setUpWithError() throws {
        continueAfterFailure = false
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatHistoryUITests-\(UUID().uuidString)", isDirectory: true)
        // The app expects a `meetings/` dir; chat history lives under `chats/`.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("meetings"), withIntermediateDirectories: true)
        try seedConversation()

        let launch = try UITestHarness.launch(storageRoot: root, suitePrefix: "ChatHistory")
        app = launch.app
        defaultsSuiteName = launch.defaultsSuiteName
    }

    override func tearDownWithError() throws {
        app?.terminate()
        try? FileManager.default.removeItem(at: root)
        UITestHarness.cleanUp(defaultsSuiteName: defaultsSuiteName)
    }

    func testPersistedConversationLoadsIntoChat() {
        let chat = app.descendants(matching: .any)["sidebar.ask"]
        XCTAssertTrue(chat.waitForExistence(timeout: 10), "ask sidebar item missing")
        chat.click()

        // The seeded conversation appears in the history list…
        XCTAssertTrue(text(containing: conversationTitle).waitForExistence(timeout: 6),
                      "seeded conversation title missing from the chat history list")

        // …and the most-recent conversation opens, rendering its messages.
        XCTAssertTrue(text(containing: assistantLine).waitForExistence(timeout: 6),
                      "seeded assistant message missing from the transcript")

        // The new-chat affordance is present in the history column.
        XCTAssertTrue(app.descendants(matching: .any)["chat.new"].exists,
                      "new-chat button missing")
    }

    private func text(containing fragment: String) -> XCUIElement {
        app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@",
                        fragment, fragment)).firstMatch
    }

    /// Write one conversation JSON in exactly the shape `ChatStore` decodes
    /// (per-conversation file, ISO-8601 dates, `role` raw values).
    private func seedConversation() throws {
        let chats = root.appendingPathComponent("chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        let id = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
        let now = ISO8601DateFormatter().string(from: Date())
        let json = """
        {
          "id": "\(id)",
          "title": "\(conversationTitle)",
          "createdAt": "\(now)",
          "updatedAt": "\(now)",
          "messages": [
            { "id": "11111111-1111-4111-8111-111111111111", "role": "user", "text": "What did we decide on pricing?" },
            { "id": "22222222-2222-4222-8222-222222222222", "role": "assistant", "text": "\(assistantLine)" }
          ]
        }
        """
        try json.write(to: chats.appendingPathComponent("\(id).json"),
                       atomically: true, encoding: .utf8)
    }
}
