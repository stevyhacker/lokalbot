import XCTest
@testable import LokalBot

final class AgentLLMEndpointTests: XCTestCase {

    private func settings(_ backend: AppSettings.SummarizerBackend) -> AppSettings {
        var s = AppSettings()
        s.summarizerBackend = backend
        return s
    }

    func testBuiltInResolvesToModelID() {
        let resolution = AgentLLMEndpointResolver.resolve(settings: settings(.builtIn))
        guard case .builtIn(let modelID) = resolution else {
            return XCTFail("expected .builtIn, got \(resolution)")
        }
        XCTAssertFalse(modelID.isEmpty)
    }

    func testAppleIntelligenceIsUnsupportedWithGuidance() {
        let resolution = AgentLLMEndpointResolver.resolve(settings: settings(.appleIntelligence))
        guard case .unsupported(let reason) = resolution else { return XCTFail() }
        XCTAssertTrue(reason.contains("Apple Intelligence"))
        XCTAssertTrue(reason.contains("Built-in"))
    }

    func testOllamaRequiresExplicitModel() {
        var s = settings(.ollama)
        s.ollamaModel = ""
        guard case .unsupported(let reason) = AgentLLMEndpointResolver.resolve(settings: s) else {
            return XCTFail()
        }
        XCTAssertTrue(reason.contains("Ollama"))
    }

    func testOllamaAppendsV1() {
        var s = settings(.ollama)
        s.ollamaModel = "qwen3:8b"
        guard case .ready(let endpoint) = AgentLLMEndpointResolver.resolve(settings: s) else {
            return XCTFail()
        }
        XCTAssertEqual(endpoint.baseURL.absoluteString, "http://localhost:11434/v1")
        XCTAssertEqual(endpoint.model, "qwen3:8b")
        XCTAssertNil(endpoint.apiKey)
        XCTAssertEqual(endpoint.contextTokens, AgentLLMEndpoint.defaultContextTokens)
    }

    func testOpenAICompatibleUsesBaseURLVerbatim() {
        var s = settings(.openAICompatible)
        s.openAIBaseURL = "http://localhost:1234/v1"
        s.openAIModel = "my-model"
        guard case .ready(let endpoint) = AgentLLMEndpointResolver.resolve(settings: s) else {
            return XCTFail()
        }
        XCTAssertEqual(endpoint.baseURL.absoluteString, "http://localhost:1234/v1")
        XCTAssertEqual(endpoint.model, "my-model")
    }

    func testOpenAICompatibleRequiresModel() {
        var s = settings(.openAICompatible)
        s.openAIModel = ""
        guard case .unsupported = AgentLLMEndpointResolver.resolve(settings: s) else { return XCTFail() }
    }
}
