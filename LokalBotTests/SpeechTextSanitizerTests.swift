import XCTest
@testable import LokalBot

final class SpeechTextSanitizerTests: XCTestCase {
    func testPlainTextRemovesMarkdownAndCitations() {
        let markdown = """
        # Summary

        - **Decision:** Ship [LokalBot](https://www.lokalbot.com). [meeting:123@00:01:02]
        - `Next step`: review _Kokoro_ output.
        """

        let text = SpeechTextSanitizer.plainText(fromMarkdown: markdown)

        XCTAssertEqual(text, "Summary Decision: Ship LokalBot. Next step: review Kokoro output.")
    }

    func testPlainTextDropsFencedCode() {
        let markdown = """
        Read this.
        ```
        do not read this aloud
        ```
        Then this.
        """

        let text = SpeechTextSanitizer.plainText(fromMarkdown: markdown)

        XCTAssertEqual(text, "Read this. Then this.")
    }
}
