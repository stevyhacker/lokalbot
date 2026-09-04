import XCTest
@testable import LokalBot

@MainActor
final class DailyEvidenceIntegrationTests: XCTestCase {
    func testCorrectionRefreshesExportAgainAfterDigestPersistence() async throws {
        let root = try temporaryRoot()
        let current = Date()
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: current)
        try MeetingFixture.write([.init(title: "Launch planning", startedAt: day)], under: root)
        let storage = StorageManager(rootURL: root)
        let meetings = try SessionLookup.loadAllMeetings(root: root)
        let meeting = try XCTUnwrap(meetings.first)
        let action = MeetingOutcomes.ActionItem(text: "Send the revised launch proposal", owner: "Me")
        try MeetingOutcomes(actionItems: [action]).write(to: meeting.folderURL(in: storage))
        let source = FileDailyEvidenceSource(root: root, calendar: calendar)
        let initial = try source.snapshot(for: day)
        let journal = root.appendingPathComponent("journal/\(DreamDay.key(for: day, calendar: calendar)).md")
        try DayDigestJournalWriter.write("Original digest", to: journal,
                                        replacing: .init(digest: nil), evidence: initial.digestEvidence(), quality: .complete)

        let exports = DailyMemoryExportScheduler(calendar: calendar, now: { current })
        defer { exports.stop() }
        let destination = root.appendingPathComponent("exports")
        let output = destination.appendingPathComponent("\(DreamDay.key(for: day, calendar: calendar)).md")
        exports.configure(.init(enabled: true, hour: 0, destinationID: destination.path)) { date in
            let service = DailyMemoryExportService(source: FileDailyMemoryExportSource(root: root), calendar: calendar)
            _ = try service.export(day: date, configuration: .init(destinationDirectory: destination, format: .markdown))
        } onError: { XCTFail($0) }
        await waitForText("Original digest", at: output)

        let generationStarted = expectation(description: "Replacement digest captured corrected evidence")
        let allowGeneration = EvidenceGenerationGate()
        let lifecycle = DayDigestLifecycle(
            storageRoot: root, calendar: calendar,
            scheduler: DayDigestScheduler(calendar: calendar, now: { current }),
            blocks: { _ in [] }, screenContexts: { _ in [] }, meetings: { meetings },
            latestActivityEvidenceAt: { _ in nil }, settings: AppSettings.init,
            generator: { snapshot, _ in
                let revision = try DayDigestJournalWriter.revision(at: journal)
                generationStarted.fulfill()
                await allowGeneration.wait()
                let text = snapshot.meetings.flatMap(\.actionReferences).map(\.text).joined(separator: "\n")
                try DayDigestJournalWriter.write(text, to: journal, replacing: revision,
                                                evidence: snapshot.digestEvidence(), quality: .complete)
                return .init(text: text, url: journal, quality: .complete)
            }, onGenerated: { exports.reconsider(day: $0) })
        defer { lifecycle.stopAutomaticGeneration() }
        lifecycle.configureAutomaticGeneration(.init(enabled: true, hour: 0), canRun: { true }, onError: { XCTFail($0) })
        let index = OutcomeIndex(storage: storage) { changed in
            let days = changed.map(\.startedAt)
            lifecycle.reconsiderEvidence(for: days)
            exports.reconsider(days: days)
        }
        index.refresh(meetings: meetings)
        XCTAssertTrue(index.correctAction(actionID: action.id, meetingID: meeting.id,
                                          text: "Send the signed final proposal", owner: nil, due: nil))
        await fulfillment(of: [generationStarted], timeout: 3)
        await waitForText("No day digest was generated", at: output)
        await allowGeneration.release()
        await waitForText("Send the signed final proposal", at: output)
        XCTAssertTrue(DayDigestGenerationMetadataStore.isCurrent(
            for: journal, evidenceSignature: try source.snapshot(for: day).digestEvidence().contentSignature))
    }

    func testJournalEditDuringGenerationPreservesUserBytesAndMetadata() async throws {
        let root = try temporaryRoot()
        let day = Date()
        let snapshot = try FileDailyEvidenceSource(root: root).snapshot(for: day)
        let journal = root.appendingPathComponent("journal/\(DreamDay.key(for: day)).md")
        try DayDigestJournalWriter.write("Generated journal", to: journal, replacing: .init(digest: nil),
                                        evidence: snapshot.digestEvidence(), quality: .complete)
        let metadataURL = DayDigestGenerationMetadataStore.metadataURL(for: journal)
        let metadata = try Data(contentsOf: metadataURL)
        let started = expectation(description: "Generation started")
        let gate = EvidenceGenerationGate()
        var didNotify = false
        let lifecycle = DayDigestLifecycle(
            storageRoot: root, blocks: { _ in [] }, screenContexts: { _ in [] }, meetings: { [] },
            latestActivityEvidenceAt: { _ in nil }, settings: AppSettings.init,
            generator: { snapshot, _ in
                let revision = try DayDigestJournalWriter.revision(at: journal)
                started.fulfill()
                await gate.wait()
                try DayDigestJournalWriter.write("New generated journal", to: journal, replacing: revision,
                                                evidence: snapshot.digestEvidence(), quality: .complete)
                return .init(text: "New generated journal", url: journal, quality: .complete)
            }, onGenerated: { _ in didNotify = true })
        let generation = Task { try await lifecycle.generate(for: day) }
        await fulfillment(of: [started], timeout: 3)
        try "My handwritten changes".write(to: journal, atomically: true, encoding: .utf8)
        await gate.release()
        do {
            _ = try await generation.value
            XCTFail("A changed journal must not be replaced")
        } catch DayDigestJournalWriter.WriteError.changedDuringGeneration {
        }
        XCTAssertEqual(try String(contentsOf: journal, encoding: .utf8), "My handwritten changes")
        XCTAssertEqual(try Data(contentsOf: metadataURL), metadata)
        XCTAssertFalse(didNotify)
    }

    private func waitForText(_ text: String, at url: URL) async {
        for _ in 0..<150 {
            if (try? String(contentsOf: url, encoding: .utf8))?.contains(text) == true { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Expected \(text) in \(url.lastPathComponent)")
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("daily-integration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}

private actor EvidenceGenerationGate {
    private var isReleased = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if isReleased { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}
