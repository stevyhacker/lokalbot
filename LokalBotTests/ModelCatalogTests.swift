import XCTest
@testable import LokalBot

final class ModelCatalogTests: XCTestCase {
    func testCatalogIDsAreUnique() {
        let ids = ModelCatalog.entries.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    func testCatalogFileNamesAreUnique() {
        let names = ModelCatalog.entries.map(\.fileName)
        XCTAssertEqual(names.count, Set(names).count)
    }

    func testCompactFallbackModelExistsInCatalog() {
        XCTAssertNotNil(ModelCatalog.entry(id: ModelCatalog.compactFallbackID))
    }

    func testRecommendedCotypingModelExistsInCatalog() {
        XCTAssertNotNil(ModelCatalog.entry(id: ModelCatalog.recommendedCotypingID))
    }

    func testRecommendedCotypingModelUsesGemmaQ5XLQuant() throws {
        let entry = try XCTUnwrap(ModelCatalog.entry(id: ModelCatalog.recommendedCotypingID))
        XCTAssertEqual(entry.id, "gemma4-e4b-q5-xl")
        XCTAssertEqual(entry.fileName, "gemma-4-E4B-it-UD-Q5_K_XL.gguf")
        XCTAssertTrue(entry.url.contains("gemma-4-E4B-it-UD-Q5_K_XL.gguf"))
    }

    func testRecommendedSummarizationAndMaximumQualityModelsExist() {
        XCTAssertNotNil(ModelCatalog.entry(id: ModelCatalog.recommendedSummarizationID))
        XCTAssertNotNil(ModelCatalog.entry(id: ModelCatalog.compactSummarizationID))
        XCTAssertNotNil(ModelCatalog.entry(id: "qwen3.6-27b"))
        XCTAssertNotNil(ModelCatalog.entry(id: "gemma4-12b"))
        XCTAssertNotNil(ModelCatalog.entry(id: "qwen3.5-4b"))
        XCTAssertNotNil(ModelCatalog.entry(id: "lfm2.5-1.2b-instruct"))
    }

    /// The fresh-install summarizer default is RAM-aware: the recommended
    /// 17.7 GB model where it fits, the compact 4B where it would be too
    /// large to load.
    func testDefaultSummarizationModelIsRAMAware() {
        let big = HardwareCapability(physicalMemoryBytes: 64 * 1_073_741_824, isAppleSilicon: true)
        let mid = HardwareCapability(physicalMemoryBytes: 32 * 1_073_741_824, isAppleSilicon: true)
        let small = HardwareCapability(physicalMemoryBytes: 16 * 1_073_741_824, isAppleSilicon: true)

        XCTAssertEqual(ModelCatalog.defaultSummarizationID(for: big),
                       ModelCatalog.recommendedSummarizationID)
        XCTAssertEqual(ModelCatalog.defaultSummarizationID(for: mid),
                       ModelCatalog.recommendedSummarizationID)
        XCTAssertEqual(ModelCatalog.defaultSummarizationID(for: small),
                       ModelCatalog.compactSummarizationID)
    }

    func testFreshSettingsDefaultMatchesThisMachinesRAMAwareChoice() {
        XCTAssertEqual(AppSettings().builtInModelID,
                       ModelCatalog.defaultSummarizationID(for: HardwareCapabilityProbe.current()))
    }

    func testQwenASRModelsAreRunnableChoices() {
        XCTAssertTrue(TranscriptionModelChoice.allCases.contains(.qwenASR17B))
        XCTAssertTrue(TranscriptionModelChoice.allCases.contains(.qwenASR06B))
    }

    func testGraniteSpeechModelIsRunnableChoice() {
        XCTAssertTrue(TranscriptionModelChoice.allCases.contains(.graniteSpeech))
        XCTAssertEqual(AppSettings().transcriptionModel, .graniteSpeech)
        XCTAssertEqual(TranscriptionModelChoice.graniteSpeech.engine.displayName, "Granite Speech 4.1 2B")
    }

    func testGraniteSpeechFilesUseDedicatedSupportFolder() {
        let root = URL(fileURLWithPath: "/tmp/lokalbot", isDirectory: true)
        XCTAssertEqual(
            GraniteSpeechEngine.modelURL(appSupport: root).path,
            "/tmp/lokalbot/granite-speech/4.1-2b/granite-speech-4.1-2b-Q4_K_M.gguf")
        XCTAssertEqual(
            GraniteSpeechEngine.projectorURL(appSupport: root).path,
            "/tmp/lokalbot/granite-speech/4.1-2b/mmproj-model-f16.gguf")
    }

    func testLlamaServerParsesServedModelNames() {
        let payload = """
        {
          "models": [{"name":"gemma-4-E4B-UD-Q5_K_XL.gguf","model":"gemma-4-E4B-UD-Q5_K_XL.gguf"}],
          "data": [{"id":"gemma-4-E4B-UD-Q5_K_XL.gguf"}]
        }
        """

        let names = LlamaServer.servedModelNames(from: Data(payload.utf8))

        XCTAssertTrue(names.contains("gemma-4-E4B-UD-Q5_K_XL.gguf"))
    }

    func testCotypingServerUsesCotabbyContextWindow() {
        XCTAssertEqual(LlamaServer.cotyping.contextTokens, 2_048)
    }

    func testDownloadURLsAreValid() {
        for entry in ModelCatalog.entries {
            XCTAssertNotNil(URL(string: entry.url), "\(entry.id) has an invalid URL")
        }
    }

    func testCatalogDownloadsAreImmutableAndIntegrityPinned() throws {
        for entry in ModelCatalog.entries {
            XCTAssertFalse(entry.url.contains("/resolve/main/"),
                           "\(entry.id) must pin an immutable Hugging Face revision")
            let digest = try XCTUnwrap(entry.sha256, "\(entry.id) needs a SHA-256 digest")
            XCTAssertNotNil(digest.range(of: #"^[0-9a-f]{64}$"#,
                                         options: .regularExpression),
                            "\(entry.id) has an invalid SHA-256 digest")
        }
    }
}
