import XCTest
@testable import LokalBot

/// The model-memory governor: pure LRU eviction policy, and the ledger's
/// register/touch/evict behavior with recorded unload hooks.
@MainActor
final class ModelResidencyTests: XCTestCase {

    private func entry(_ id: String, gb: Int64, age: TimeInterval) -> ModelResidencyPolicy.Entry {
        .init(id: id, bytes: gb * 1_073_741_824,
              lastUsed: Date(timeIntervalSince1970: 1_000_000 - age))
    }

    // MARK: - Policy

    func testNoEvictionWhenEverythingFits() {
        let victims = ModelResidencyPolicy.evictions(
            residents: [entry("a", gb: 4, age: 100)],
            incomingID: "b", incomingBytes: 4 * 1_073_741_824,
            budgetBytes: 8 * 1_073_741_824)
        XCTAssertTrue(victims.isEmpty)
    }

    func testEvictsLeastRecentlyUsedFirstUntilItFits() {
        let victims = ModelResidencyPolicy.evictions(
            residents: [entry("newest", gb: 3, age: 10),
                        entry("oldest", gb: 6, age: 300),
                        entry("middle", gb: 2, age: 100)],
            incomingID: "incoming", incomingBytes: 5 * 1_073_741_824,
            budgetBytes: 10 * 1_073_741_824)
        // 3+6+2+5 = 16 GB against 10: dropping "oldest" (6) reaches 10 exactly.
        XCTAssertEqual(victims, ["oldest"])
    }

    func testEvictsSeveralWhenOneIsNotEnough() {
        let victims = ModelResidencyPolicy.evictions(
            residents: [entry("old", gb: 2, age: 300), entry("mid", gb: 2, age: 200),
                        entry("new", gb: 2, age: 10)],
            incomingID: "incoming", incomingBytes: 7 * 1_073_741_824,
            budgetBytes: 9 * 1_073_741_824)
        XCTAssertEqual(victims, ["old", "mid"])
    }

    func testIncomingIDIsNeverAVictim() {
        // A model swap on the same runtime replaces in place: its old row must
        // not be evicted (the runtime restart handles the old weights).
        let victims = ModelResidencyPolicy.evictions(
            residents: [entry("server", gb: 8, age: 300), entry("other", gb: 4, age: 10)],
            incomingID: "server", incomingBytes: 9 * 1_073_741_824,
            budgetBytes: 12 * 1_073_741_824)
        XCTAssertEqual(victims, ["other"])
    }

    func testOversizedIncomingEvictsEverythingElseAndStillLoads() {
        let victims = ModelResidencyPolicy.evictions(
            residents: [entry("a", gb: 2, age: 100), entry("b", gb: 2, age: 200)],
            incomingID: "huge", incomingBytes: 64 * 1_073_741_824,
            budgetBytes: 16 * 1_073_741_824)
        XCTAssertEqual(Set(victims), ["a", "b"])
    }

    // MARK: - Ledger

    func testRegisterUpsertsTouchAndUnregister() {
        let residency = ModelResidency(budgetBytes: .max)
        residency.register(id: "a", label: "model-a", bytes: 100, unload: {})
        residency.register(id: "b", label: "model-b", bytes: 50, unload: {})
        XCTAssertEqual(residency.totalBytes, 150)

        residency.register(id: "a", label: "model-a2", bytes: 70, unload: {})
        XCTAssertEqual(residency.residents.count, 2)
        XCTAssertEqual(residency.totalBytes, 120)
        XCTAssertEqual(residency.residents.first { $0.id == "a" }?.label, "model-a2")

        let before = residency.residents.first { $0.id == "b" }!.lastUsed
        residency.touch(id: "b")
        XCTAssertGreaterThanOrEqual(residency.residents.first { $0.id == "b" }!.lastUsed, before)

        residency.unregister(id: "a")
        XCTAssertEqual(residency.residents.map(\.id), ["b"])
    }

    func testWillLoadRunsUnloadHooksForVictimsOnly() async {
        final class Unloads { var ids: [String] = [] }
        let unloads = Unloads()
        let residency = ModelResidency(budgetBytes: 10)
        residency.register(id: "old", label: "old", bytes: 6) { unloads.ids.append("old") }
        residency.register(id: "new", label: "new", bytes: 3) { unloads.ids.append("new") }
        residency.touch(id: "new")

        await residency.willLoad(id: "incoming", bytes: 5)
        XCTAssertEqual(unloads.ids, ["old"])
        XCTAssertEqual(residency.residents.map(\.id), ["new"])

        // The incoming runtime registers itself after its load completes.
        residency.register(id: "incoming", label: "incoming", bytes: 5, unload: {})
        XCTAssertEqual(residency.totalBytes, 8)
    }
}
