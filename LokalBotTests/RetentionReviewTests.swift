import XCTest
@testable import LokalBot

@MainActor
final class RetentionReviewTests: XCTestCase {
    func testPreviewPreservesSavedMomentsAndDoesNotDeleteUntilApplied() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("retention-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ActivityStore(databaseURL: url)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = now.addingTimeInterval(-20 * 86_400)
        let expired = try store.insertScreenshot(ts: old, path: "", app: "Editor", ocr: "original text")
        let saved = try store.insertScreenshot(ts: old, path: "", app: "Editor", ocr: "saved text")
        try store.saveMoment(snapshotID: saved)
        let review = try store.retentionReview(days: 7, keepTextForever: false, now: now)
        XCTAssertEqual(review.candidates.map(\.id), [expired])
        XCTAssertEqual(review.textCount, 1)
        XCTAssertEqual(review.savedCount, 1)
        XCTAssertEqual(store.ocrText(snapshotID: expired), "original text")
        try store.clearRetainedText(ids: [expired, saved])
        XCTAssertNil(store.ocrText(snapshotID: expired))
        XCTAssertEqual(store.ocrText(snapshotID: saved), "saved text")
    }

    func testReviewRequiresApprovalWhenScopeExpandsAndAllowsNewBookmarks() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("retention-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ActivityStore(databaseURL: url)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = now.addingTimeInterval(-20 * 86_400)
        let first = try store.insertScreenshot(ts: old, path: "", app: "Editor", ocr: "first")
        let reviewed = try store.retentionReview(days: 7, keepTextForever: false, now: now)
        try store.saveMoment(snapshotID: first)
        XCTAssertTrue(reviewed.covers(try store.retentionReview(days: 7, keepTextForever: false, now: now)))
        _ = try store.insertScreenshot(ts: old, path: "", app: "Editor", ocr: "newly eligible")
        XCTAssertFalse(reviewed.covers(try store.retentionReview(days: 7, keepTextForever: false, now: now)))
    }
}
