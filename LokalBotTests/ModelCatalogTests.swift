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

    func testRecommendedCotypingModelUsesBenchmarkedLFMQuant() throws {
        let entry = try XCTUnwrap(ModelCatalog.entry(id: ModelCatalog.recommendedCotypingID))
        XCTAssertEqual(entry.id, "lfm2.5-1.2b-instruct")
        XCTAssertEqual(entry.fileName, "LFM2.5-1.2B-Instruct-Q4_K_M.gguf")
        XCTAssertTrue(entry.url.contains("LFM2.5-1.2B-Instruct-Q4_K_M.gguf"))
        XCTAssertEqual(entry.sizeBytes, 730_895_584)
        XCTAssertEqual(entry.sizeGB, 0.73)
        XCTAssertEqual(
            ModelCatalog.recommendedCotypingLicenseURL.absoluteString,
            "https://docs.liquid.ai/lfm/help/model-license")
    }

    func testRecommendedSummarizationAndMaximumQualityModelsExist() {
        XCTAssertNotNil(ModelCatalog.entry(id: ModelCatalog.recommendedSummarizationID))
        XCTAssertNotNil(ModelCatalog.entry(id: ModelCatalog.defaultSummarizationID))
        XCTAssertNotNil(ModelCatalog.entry(id: "qwen3.6-27b"))
        XCTAssertNotNil(ModelCatalog.entry(id: "gemma4-12b"))
        XCTAssertNotNil(ModelCatalog.entry(id: "qwen3.5-4b"))
        XCTAssertNotNil(ModelCatalog.entry(id: "lfm2.5-1.2b-instruct"))
    }

    func testFreshSettingsDefaultToQwen35FourBOnEveryMac() {
        XCTAssertEqual(ModelCatalog.defaultSummarizationID, "qwen3.5-4b")
        XCTAssertEqual(AppSettings().builtInModelID, ModelCatalog.defaultSummarizationID)
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

    func testGraniteSpeechRequestAuthenticatesToPrivateServer() throws {
        let wav = FileManager.default.temporaryDirectory
            .appendingPathComponent("granite-auth-\(UUID().uuidString).wav")
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: wav)
        defer { try? FileManager.default.removeItem(at: wav) }

        let request = try GraniteSpeechEngine.makeTranscriptionRequest(
            serverBaseURL: URL(string: "http://127.0.0.1:17875/v1")!,
            authenticationToken: "granite-secret",
            boundary: "granite-test-boundary",
            wav: wav)

        XCTAssertEqual(request.url?.absoluteString,
                       "http://127.0.0.1:17875/v1/audio/transcriptions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"),
                       "Bearer granite-secret")
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

    func testKeystrokeScaleEntriesOmitHeavyAndLegacyModels() {
        let ids = ModelCatalog.keystrokeScaleEntries(custom: []).map(\.id)
        XCTAssertFalse(ids.contains("qwen3.6-35b-a3b"), "17 GB models are not keystroke-scale")
        XCTAssertFalse(ids.contains("qwen3.6-27b"))
        XCTAssertFalse(ids.contains("gemma4-12b"))
        XCTAssertFalse(ids.contains("gemma4-e4b"), "the legacy Gemma quant is superseded")
        XCTAssertTrue(ids.contains(ModelCatalog.recommendedCotypingID))
        XCTAssertTrue(ids.contains("qwen3.5-2b"))
        XCTAssertTrue(ids.contains("lfm2.5-1.2b-instruct"))
    }

    func testKeystrokeScaleEntriesKeepTheActiveSelection() {
        let ids = ModelCatalog.keystrokeScaleEntries(
            custom: [], keeping: "qwen3.6-27b").map(\.id)
        XCTAssertTrue(ids.contains("qwen3.6-27b"),
                      "an existing selection must stay pickable, filter or not")
    }

    func testKeystrokeScaleEntriesAlwaysIncludeCustomModels() {
        let custom = ModelCatalog.Entry(
            id: "my-local-model", displayName: "My local model",
            fileName: "my-local-model.gguf", url: "https://example.invalid/x.gguf",
            sha256: "", sizeBytes: nil, sizeGB: 42, blurb: "",
            disablesThinking: false)
        let ids = ModelCatalog.keystrokeScaleEntries(custom: [custom]).map(\.id)
        XCTAssertTrue(ids.contains("my-local-model"),
                      "user-added models are never filtered, whatever their size")
    }

    func testCatalogDisplayNamesAreUnique() {
        let names = ModelCatalog.entries.map(\.displayName)
        XCTAssertEqual(Set(names).count, names.count,
                       "two catalog entries render identically in pickers: \(names)")
    }
}
