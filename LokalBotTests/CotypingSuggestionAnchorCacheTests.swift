import AppKit
import XCTest
@testable import LokalBot

// MARK: - Suggestion anchor cache

final class CotypingSuggestionAnchorCacheTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_000_000)

    private func makeCache() -> CotypingSuggestionAnchorCache {
        CotypingSuggestionAnchorCache(now: { self.clock })
    }

    func testFreshAnchorMatchesAtZeroConsumed() {
        var cache = makeCache()
        cache.record(identityKey: "field", precedingText: "Hello", fullText: " world again")
        XCTAssertEqual(cache.remainder(identityKey: "field", precedingText: "Hello"), " world again")
    }

    func testTypeThroughConsumesPrefix() {
        var cache = makeCache()
        cache.record(identityKey: "field", precedingText: "Hello", fullText: " world again")
        XCTAssertEqual(cache.remainder(identityKey: "field", precedingText: "Hello wo"), "rld again")
    }

    func testBackspaceRollbackRestoresEarlierPosition() {
        var cache = makeCache()
        cache.record(identityKey: "field", precedingText: "Hello", fullText: " world again")
        XCTAssertEqual(cache.remainder(identityKey: "field", precedingText: "Hello wo"), "rld again")
        XCTAssertEqual(cache.remainder(identityKey: "field", precedingText: "Hello"), " world again")
    }

    func testFullyConsumedSuggestionNeverReoffersItsTail() {
        var cache = makeCache()
        cache.record(identityKey: "field", precedingText: "Hello", fullText: " world")
        XCTAssertNil(cache.remainder(identityKey: "field", precedingText: "Hello world"))
    }

    func testDivergentTypingDoesNotMatch() {
        var cache = makeCache()
        cache.record(identityKey: "field", precedingText: "Hello", fullText: " world again")
        XCTAssertNil(cache.remainder(identityKey: "field", precedingText: "Hello wa"))
    }

    func testDifferentFieldDoesNotMatch() {
        var cache = makeCache()
        cache.record(identityKey: "first", precedingText: "Hello", fullText: " world")
        XCTAssertNil(cache.remainder(identityKey: "second", precedingText: "Hello"))
    }

    func testDeepestConsumedMatchWins() {
        var cache = makeCache()
        cache.record(identityKey: "field", precedingText: "Hello", fullText: " world again")
        cache.record(identityKey: "field", precedingText: "Hello wo", fullText: "rld forever")
        XCTAssertEqual(cache.remainder(identityKey: "field", precedingText: "Hello wor"), "ld again")
    }

    func testEntriesExpire() {
        var cache = makeCache()
        cache.record(identityKey: "field", precedingText: "Hello", fullText: " world")
        clock = clock.addingTimeInterval(CotypingSuggestionAnchorCache.maxEntryAge + 1)
        XCTAssertNil(cache.remainder(identityKey: "field", precedingText: "Hello"))
    }

    func testCapacityEvictsOldest() {
        var cache = makeCache()
        for index in 0..<(CotypingSuggestionAnchorCache.capacity + 4) {
            cache.record(identityKey: "field", precedingText: "prefix \(index)", fullText: "suffix \(index)")
        }
        XCTAssertNil(cache.remainder(identityKey: "field", precedingText: "prefix 0"))
        XCTAssertEqual(
            cache.remainder(
                identityKey: "field",
                precedingText: "prefix \(CotypingSuggestionAnchorCache.capacity + 3)"),
            "suffix \(CotypingSuggestionAnchorCache.capacity + 3)")
    }

    func testLongPrefixesMatchOnTheBoundedTail() {
        var cache = makeCache()
        let longPrefix = String(repeating: "a", count: 2_000) + " ending here"
        cache.record(identityKey: "field", precedingText: longPrefix, fullText: " and more")
        XCTAssertEqual(cache.remainder(identityKey: "field", precedingText: longPrefix + " and"), " more")
    }

    func testRemoveAllEmptiesTheCache() {
        var cache = makeCache()
        cache.record(identityKey: "field", precedingText: "Hello", fullText: " world")
        cache.removeAll()
        XCTAssertNil(cache.remainder(identityKey: "field", precedingText: "Hello"))
    }
}
