import XCTest
@testable import LokalBot

final class PipelineJobStoreTests: XCTestCase {
    private var databaseURL: URL!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PipelineJobStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        databaseURL = dir.appendingPathComponent("test.sqlite")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent())
    }

    private func makeStore() -> PipelineJobStore {
        PipelineJobStore(databaseURL: databaseURL)
    }

    func testEnqueuedJobIsPendingWithItsFlags() {
        let store = makeStore()
        let id = UUID()

        store.enqueue(meetingID: id, transcribe: true, summarize: false)

        let pending = store.pendingJobs()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.meetingID, id)
        XCTAssertEqual(pending.first?.transcribe, true)
        XCTAssertEqual(pending.first?.summarize, false)
        XCTAssertEqual(pending.first?.attempts, 0)
    }

    func testCompletedJobIsRemoved() {
        let store = makeStore()
        let id = UUID()
        store.enqueue(meetingID: id, transcribe: true, summarize: true)

        store.markCompleted(meetingID: id)

        XCTAssertTrue(store.pendingJobs().isEmpty)
    }

    /// A crash mid-processing leaves the row with its attempt already burned,
    /// and once the cap is reached the job stops auto-resuming — a meeting
    /// that reliably kills the app must not crash-loop every launch.
    func testJobStopsResumingAfterAttemptCap() {
        let store = makeStore()
        let id = UUID()
        store.enqueue(meetingID: id, transcribe: true, summarize: true)

        for attempt in 1...PipelineJobStore.maxAutoResumeAttempts {
            XCTAssertEqual(store.pendingJobs().count, 1, "attempt \(attempt) should still resume")
            store.markStarted(meetingID: id)
        }

        XCTAssertTrue(store.pendingJobs().isEmpty)
    }

    /// An explicit user retry is a fresh decision — it resets the crash-loop
    /// counter instead of staying parked forever.
    func testExplicitReenqueueResetsAttempts() {
        let store = makeStore()
        let id = UUID()
        store.enqueue(meetingID: id, transcribe: true, summarize: true)
        for _ in 1...PipelineJobStore.maxAutoResumeAttempts {
            store.markStarted(meetingID: id)
        }
        XCTAssertTrue(store.pendingJobs().isEmpty)

        store.enqueue(meetingID: id, transcribe: false, summarize: true)

        let pending = store.pendingJobs()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.attempts, 0)
        XCTAssertEqual(pending.first?.transcribe, false)
        XCTAssertEqual(pending.first?.summarize, true)
    }

    func testPendingJobsAreOldestFirst() {
        let store = makeStore()
        let first = UUID(), second = UUID()
        store.enqueue(meetingID: second, transcribe: true, summarize: true,
                      at: Date(timeIntervalSince1970: 2_000))
        store.enqueue(meetingID: first, transcribe: true, summarize: true,
                      at: Date(timeIntervalSince1970: 1_000))

        XCTAssertEqual(store.pendingJobs().map(\.meetingID), [first, second])
    }

    func testPruneDropsJobsForDeletedMeetings() {
        let store = makeStore()
        let kept = UUID(), deleted = UUID()
        store.enqueue(meetingID: kept, transcribe: true, summarize: true)
        store.enqueue(meetingID: deleted, transcribe: true, summarize: true)

        store.prune(existing: [kept])

        XCTAssertEqual(store.pendingJobs().map(\.meetingID), [kept])
    }

    /// The queue survives the connection — a new store over the same file
    /// (i.e. the next app launch) sees the unfinished job.
    func testJobsSurviveReopen() {
        let id = UUID()
        makeStore().enqueue(meetingID: id, transcribe: true, summarize: true)

        XCTAssertEqual(makeStore().pendingJobs().first?.meetingID, id)
    }

    func testEnqueueReportsUnavailableDatabaseInsteadOfSilentlyDroppingJob() {
        let missingParent = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString)", isDirectory: true)
        let store = PipelineJobStore(
            databaseURL: missingParent.appendingPathComponent("test.sqlite"))

        XCTAssertFalse(store.enqueue(
            meetingID: UUID(), transcribe: true, summarize: true))
        XCTAssertTrue(store.pendingJobs().isEmpty)
    }
}
