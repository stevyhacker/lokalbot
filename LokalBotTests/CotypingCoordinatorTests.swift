import XCTest
@testable import LokalBot

// MARK: - Scripted engine

/// Records every request and returns (or throws) a canned result, so the
/// coordinator's engine-facing paths run without a model or server.
@MainActor
private final class ScriptedCotypingEngine: CotypingCompleting {
    var result: Result<String, Error> = .success("")
    private(set) var requests: [CotypingRequest] = []

    func generate(_ request: CotypingRequest) async throws -> CotypingNormalizationResult {
        requests.append(request)
        return CotypingNormalizationResult(text: try result.get(), suppression: nil)
    }
}

private struct EngineBoom: Error {}

// MARK: - Coordinator

/// Most of the coordinator needs live AX + event taps, so these tests pin the
/// paths that run before any permission check: the settings gate in
/// `applySettings()` (which must bail out without touching AX) and the
/// permission-free `previewSuggestion` pipeline the in-app playground uses.
@MainActor
final class CotypingCoordinatorTests: XCTestCase {
    private var tempDir: URL!
    private var engine: ScriptedCotypingEngine!
    private var settings = AppSettings()

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lokalbot-cotyping-coordinator-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        engine = ScriptedCotypingEngine()
        settings = AppSettings()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeCoordinator() -> CotypingCoordinator {
        CotypingCoordinator(
            engine: engine,
            settingsProvider: { [settings] in settings },
            learningStore: CotypingLearningStore(storageRoot: tempDir),
            selfBundleID: "me.dotenv.LokalBot.tests")
    }

    func testApplySettingsWithCotypingOffDisablesWithoutRunning() {
        settings.cotypingEnabled = false
        let coordinator = makeCoordinator()

        coordinator.applySettings()

        XCTAssertFalse(coordinator.isRunning)
        XCTAssertEqual(coordinator.state, .disabled("Cotyping is off."))
    }

    func testStopWithoutReasonReturnsToIdle() {
        settings.cotypingEnabled = false
        let coordinator = makeCoordinator()
        coordinator.applySettings()

        coordinator.stop()

        XCTAssertFalse(coordinator.isRunning)
        XCTAssertEqual(coordinator.state, .idle)
    }

    func testPreviewSuggestionRunsThePipelineAgainstTheEngine() async throws {
        engine.result = .success("ld, how are you?")

        let text = try await makeCoordinator()
            .previewSuggestion(precedingText: "Hello wor", trailingText: "ld!")

        XCTAssertEqual(text, "ld, how are you?")
        XCTAssertEqual(engine.requests.count, 1)
        let request = try XCTUnwrap(engine.requests.first)
        XCTAssertTrue(request.prefixText.hasSuffix("Hello wor"),
                      "the caret prefix must reach the engine")
        XCTAssertTrue(request.prompt.contains("Hello wor"))
        XCTAssertEqual(request.trailingText, "ld!")
        XCTAssertTrue(request.forceWordContinuation,
                      "word characters on both sides of the caret must force word continuation")
    }

    func testPreviewSuggestionWithBlankPrefixSkipsTheEngine() async throws {
        let text = try await makeCoordinator()
            .previewSuggestion(precedingText: "   \n  ")

        XCTAssertEqual(text, "")
        XCTAssertTrue(engine.requests.isEmpty,
                      "a blank-before-caret field must never hit the model")
    }

    func testPreviewSuggestionPropagatesEngineFailure() async {
        engine.result = .failure(EngineBoom())

        do {
            _ = try await makeCoordinator().previewSuggestion(precedingText: "Hello wor")
            XCTFail("an engine failure must surface to the playground caller")
        } catch is EngineBoom {
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }
}
