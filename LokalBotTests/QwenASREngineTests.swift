import XCTest
@testable import LokalBotV3

final class QwenASREngineTests: XCTestCase {
    /// The cache dir handed to the Qwen3ASR package must be the Hub layout
    /// `base/models/<org>/<model>` so its downloader writes into the same
    /// directory `fromPretrained` loads from. A flat path makes the package's
    /// `makeHubApi` fall back to `~/Library/Caches`, leaving the load dir empty
    /// and surfacing "No safetensors files found".
    func testHubStyleCacheDirMatchesPackageLayout() {
        let base = URL(fileURLWithPath: "/tmp/qwen3-asr-models", isDirectory: true)
        let dir = QwenASREngine.hubStyleCacheDir(
            base: base, modelID: "aufklarer/Qwen3-ASR-0.6B-MLX-4bit")
        XCTAssertEqual(
            dir.path, "/tmp/qwen3-asr-models/models/aufklarer/Qwen3-ASR-0.6B-MLX-4bit")
    }
}
