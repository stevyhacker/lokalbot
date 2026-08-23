import XCTest
@testable import LokalBot

final class ModelRolesTests: XCTestCase {
    func testCoreReadyOnlyWhenEveryRoleIsReady() {
        let snapshot = makeSnapshot(statuses: [
            .transcribe: .ready,
            .think: .ready,
            .autocomplete: .ready,
        ])

        XCTAssertTrue(snapshot.coreReady)
        XCTAssertEqual(snapshot.primaryActionStatus, .ready)
    }

    func testFailureStopsOnboardingSpinnerAndOffersRecovery() {
        let snapshot = makeSnapshot(statuses: [
            .transcribe: .ready,
            .think: .needsAttention("Network unavailable"),
            .autocomplete: .unavailable,
        ])

        XCTAssertEqual(snapshot.primaryActionStatus, .needsAttention("Network unavailable"))
        XCTAssertEqual(
            snapshot.detail,
            "A selected model needs attention before the stack is ready.")
    }

    func testPreparationAndDownloadExposeRoleSpecificProgress() {
        let preparing = makeSnapshot(statuses: [
            .transcribe: .preparing(progress: 0.25, label: "Loading vocabulary…"),
            .think: .unavailable,
            .autocomplete: .unavailable,
        ])
        let downloading = makeSnapshot(statuses: [
            .transcribe: .ready,
            .think: .downloading(progress: 0.42),
            .autocomplete: .unavailable,
        ])

        XCTAssertEqual(
            preparing.primaryActionStatus,
            .preparing(progress: 0.25, label: "Loading vocabulary…"))
        XCTAssertEqual(downloading.primaryActionStatus.label, "Downloading… 42%")
    }

    func testMissingStatusDefaultsToUnavailable() {
        let snapshot = makeSnapshot(statuses: [.transcribe: .ready])

        XCTAssertEqual(snapshot[.think], .unavailable)
        XCTAssertFalse(snapshot.coreReady)
    }

    private func makeSnapshot(
        statuses: [ModelRole: ModelRoleStatus]
    ) -> ModelRolesSnapshot {
        ModelRolesSnapshot(
            readiness: ModelReadinessSnapshot(
                transcriptionReady: statuses[.transcribe]?.isReady == true,
                thinkReady: statuses[.think]?.isReady == true,
                autocompleteReady: statuses[.autocomplete]?.isReady == true,
                provenance: .local,
                storedBytes: 0,
                availableBytes: nil,
                activeDownloads: statuses.values.filter(\.isWorking).count,
                failedDownloads: statuses.values.filter {
                    $0.errorMessage != nil
                }.count),
            statuses: statuses)
    }
}
