import XCTest
@testable import LokalBot

@MainActor
final class ThinkExecutionTests: XCTestCase {
    func testBuiltInManagedRecoveryDoesNotStackProviderRetry() {
        let execution = ThinkExecution(storage: StorageManager())
        var settings = AppSettings()
        settings.summarizerBackend = .builtIn
        let error = TextEngineError.serverUnreachable(
            "http://127.0.0.1:17872",
            transportCode: -1_004)

        XCTAssertNil(execution.retryDelay(
            for: error,
            settings: settings,
            attempt: 0,
            jitter: 0))
    }

    func testRemoteThinkKeepsOneBoundedTransientRetry() {
        let execution = ThinkExecution(storage: StorageManager())
        var settings = AppSettings()
        settings.summarizerBackend = .openAICompatible
        let error = TextEngineError.httpStatus(
            code: 503,
            detail: "warming",
            retryAfter: nil)

        XCTAssertEqual(
            execution.retryDelay(
                for: error,
                settings: settings,
                attempt: 0,
                jitter: 0),
            1)
        XCTAssertNil(execution.retryDelay(
            for: error,
            settings: settings,
            attempt: 1,
            jitter: 0))
    }
}
