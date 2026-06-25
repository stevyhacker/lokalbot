import XCTest
@testable import LokalBotV3

final class ModelCatalogTests: XCTestCase {
    func testCatalogIDsAreUnique() {
        let ids = ModelCatalog.entries.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    func testCatalogFileNamesAreUnique() {
        let names = ModelCatalog.entries.map(\.fileName)
        XCTAssertEqual(names.count, Set(names).count)
    }

    func testBundledModelExistsInCatalog() {
        XCTAssertNotNil(ModelCatalog.entry(id: ModelCatalog.bundledID))
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
        XCTAssertNotNil(ModelCatalog.entry(id: "qwen3.6-27b"))
        XCTAssertNotNil(ModelCatalog.entry(id: "gemma4-12b"))
        XCTAssertNotNil(ModelCatalog.entry(id: "qwen3.5-4b"))
        XCTAssertNotNil(ModelCatalog.entry(id: "lfm2.5-1.2b-instruct"))
    }

    func testQwenASRModelsAreRunnableChoices() {
        XCTAssertTrue(TranscriptionModelChoice.allCases.contains(.qwenASR17B))
        XCTAssertTrue(TranscriptionModelChoice.allCases.contains(.qwenASR06B))
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

    func testCotypistModelReuseRequiresGGUFAtExpectedPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cotypist-model-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let models = root
            .appendingPathComponent("app.cotypist.Cotypist", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        let model = models.appendingPathComponent("gemma-4-E4B-UD-Q5_K_XL.gguf")
        try Data("GGUF".utf8).write(to: model)

        XCTAssertEqual(ModelCatalog.cotypistModelURL(appSupport: root), model)
    }

    func testCotypistModelReuseIgnoresInvalidFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cotypist-invalid-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let models = root
            .appendingPathComponent("app.cotypist.Cotypist", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try Data("nope".utf8)
            .write(to: models.appendingPathComponent("gemma-4-E4B-UD-Q5_K_XL.gguf"))

        XCTAssertNil(ModelCatalog.cotypistModelURL(appSupport: root))
    }

    func testDownloadURLsAreValid() {
        for entry in ModelCatalog.entries {
            XCTAssertNotNil(URL(string: entry.url), "\(entry.id) has an invalid URL")
        }
    }
}
