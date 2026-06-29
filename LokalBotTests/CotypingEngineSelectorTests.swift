import XCTest
@testable import LokalBot

final class CotypingEngineSelectorTests: XCTestCase {
    private let modelURL = URL(fileURLWithPath: "/models/gemma.gguf")

    func testUsesLocalWhenFlagOnAppleSiliconAndModelResolves() {
        var s = AppSettings(); s.cotypingInProcessRuntime = true
        XCTAssertTrue(CotypingEngineSelector.shouldUseLocal(
            settings: s, modelURL: modelURL, isAppleSilicon: true))
    }

    func testFallsBackWhenFlagOff() {
        var s = AppSettings(); s.cotypingInProcessRuntime = false
        XCTAssertFalse(CotypingEngineSelector.shouldUseLocal(
            settings: s, modelURL: modelURL, isAppleSilicon: true))
    }

    func testFallsBackOnIntel() {
        var s = AppSettings(); s.cotypingInProcessRuntime = true
        XCTAssertFalse(CotypingEngineSelector.shouldUseLocal(
            settings: s, modelURL: modelURL, isAppleSilicon: false))
    }

    func testFallsBackWhenModelMissing() {
        var s = AppSettings(); s.cotypingInProcessRuntime = true
        XCTAssertFalse(CotypingEngineSelector.shouldUseLocal(
            settings: s, modelURL: nil, isAppleSilicon: true))
    }
}
