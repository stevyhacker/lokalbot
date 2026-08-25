import Foundation

/// Owns the complete Day Digest lifecycle shared by manual, scheduled, and
/// headless entry points. Callers choose when to request a digest; this module
/// owns what evidence belongs to that request, where the journal lives, how
/// freshness is derived, and how automatic repair is scheduled.
@MainActor
final class DayDigestLifecycle {
    struct Snapshot: Equatable, Sendable {
        var text: String?
        var modifiedAt: Date?
        var latestEvidenceAt: Date?

        var isStale: Bool {
            DayDigestFreshness.isStale(
                digestModifiedAt: modifiedAt,
                latestEvidenceAt: latestEvidenceAt)
        }
    }

    typealias Generator = @MainActor (
        _ day: Date,
        _ blocks: [ActivityBlock],
        _ meetings: [Meeting],
        _ screenContexts: [DayScreenContext],
        _ settings: AppSettings
    ) async throws -> DayDigestGenerationResult

    private struct EvidenceInput {
        var blocks: [ActivityBlock]
        var meetings: [Meeting]
        var screenContexts: [DayScreenContext]

        var isEmpty: Bool {
            blocks.isEmpty && meetings.isEmpty && screenContexts.isEmpty
        }
    }

    private let storageRoot: URL
    private let blocks: (Date) -> [ActivityBlock]
    private let screenContexts: (Date) -> [DayScreenContext]
    private let meetings: () -> [Meeting]
    private let latestActivityEvidenceAt: (Date) -> Date?
    private let settings: () -> AppSettings
    private let generator: Generator
    private let calendar: Calendar
    private let scheduler: DayDigestScheduler

    init(
        storageRoot: URL,
        calendar: Calendar = .current,
        scheduler: DayDigestScheduler? = nil,
        blocks: @escaping (Date) -> [ActivityBlock],
        screenContexts: @escaping (Date) -> [DayScreenContext],
        meetings: @escaping () -> [Meeting],
        latestActivityEvidenceAt: @escaping (Date) -> Date?,
        settings: @escaping () -> AppSettings,
        generator: @escaping Generator
    ) {
        self.storageRoot = storageRoot
        self.calendar = calendar
        self.scheduler = scheduler ?? DayDigestScheduler()
        self.blocks = blocks
        self.screenContexts = screenContexts
        self.meetings = meetings
        self.latestActivityEvidenceAt = latestActivityEvidenceAt
        self.settings = settings
        self.generator = generator
    }

    convenience init(
        storage: StorageManager,
        activityStore: ActivityStore,
        pipeline: ProcessingPipeline,
        meetings: @escaping () -> [Meeting],
        settings: @escaping () -> AppSettings
    ) {
        self.init(
            storageRoot: storage.rootURL,
            blocks: { activityStore.blocks(on: $0) },
            screenContexts: { activityStore.screenContexts(on: $0) },
            meetings: meetings,
            latestActivityEvidenceAt: { activityStore.latestEvidenceAt(on: $0) },
            settings: settings,
            generator: { day, blocks, meetings, screenContexts, settings in
                try await pipeline.generateDayDigest(
                    for: day,
                    blocks: blocks,
                    meetings: meetings,
                    screenContexts: screenContexts,
                    config: settings)
            })
    }

    func journalURL(for day: Date) -> URL {
        storageRoot.appendingPathComponent("journal/\(DreamDay.key(for: day, calendar: calendar)).md")
    }

    func snapshot(for day: Date) -> Snapshot {
        let url = journalURL(for: day)
        let text = try? String(contentsOf: url, encoding: .utf8)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return Snapshot(
            text: text,
            modifiedAt: attributes?[.modificationDate] as? Date,
            latestEvidenceAt: latestEvidenceAt(for: day))
    }

    func meetings(for day: Date, includeInProgress: Bool = true) -> [Meeting] {
        meetings().filter { meeting in
            calendar.isDate(meeting.startedAt, inSameDayAs: day)
                && (includeInProgress || meeting.endedAt != nil)
        }
    }

    func latestEvidenceAt(for day: Date) -> Date? {
        let finishedMeetings = meetings(for: day, includeInProgress: false)
        let meetingEnd = finishedMeetings.compactMap(\.endedAt).max()
        let meetingArtifactWrite = finishedMeetings
            .compactMap(latestArtifactWriteAt(for:))
            .max()
        return [latestActivityEvidenceAt(day), meetingEnd, meetingArtifactWrite]
            .compactMap { $0 }
            .max()
    }

    @discardableResult
    func generate(
        for day: Date,
        settings override: AppSettings? = nil
    ) async throws -> DayDigestGenerationResult {
        let input = evidenceInput(for: day)
        return try await generator(
            day,
            input.blocks,
            input.meetings,
            input.screenContexts,
            override ?? settings())
    }

    func configureAutomaticGeneration(
        _ configuration: DayDigestScheduler.Configuration,
        canRun: @escaping () -> Bool,
        onError: @escaping (String) -> Void
    ) {
        scheduler.configure(
            configuration,
            digestModifiedAt: { [weak self] day in
                guard let self else { return nil }
                return self.automaticCompletionAt(for: day)
            },
            latestEvidenceAt: { [weak self] day in
                self?.latestEvidenceAt(for: day)
            },
            canRun: canRun,
            generate: { [weak self] day in
                guard let self else {
                    throw TextEngineError.unavailable("LokalBot is shutting down.")
                }
                let input = self.evidenceInput(for: day)
                guard !input.isEmpty else { return .deferred }
                let result = try await self.generator(
                    day,
                    input.blocks,
                    input.meetings,
                    input.screenContexts,
                    self.settings())
                return result.quality.needsRepair ? .needsRepair : .completed
            },
            onError: onError)
    }

    func stopAutomaticGeneration() {
        scheduler.stop()
    }

    private func evidenceInput(for day: Date) -> EvidenceInput {
        EvidenceInput(
            blocks: blocks(day),
            meetings: meetings(for: day, includeInProgress: false),
            screenContexts: screenContexts(day))
    }

    /// Summaries and outcomes are produced after a meeting ends, and both are
    /// consumed by `ProcessingPipeline.generateDayDigest`. Their writes must
    /// therefore advance the evidence watermark even though the meeting's
    /// `endedAt` value is unchanged.
    private func latestArtifactWriteAt(for meeting: Meeting) -> Date? {
        let folder = storageRoot.appendingPathComponent(
            meeting.relativePath,
            isDirectory: true)
        return DayDigestMeetingArtifacts.latestModifiedAt(in: folder)
    }

    /// Preserve the scheduler's once-per-evening policy for ordinary activity,
    /// but invalidate its completion marker when a digest predates meeting
    /// artifacts it actually consumes. This makes the next quiet tick repair
    /// the journal without regenerating it for every later activity sample.
    private func automaticCompletionAt(for day: Date) -> Date? {
        let completedAt = DayDigestGenerationMetadataStore.completedAt(
            for: journalURL(for: day))
        guard let completedAt else { return nil }
        let latestArtifactWrite = meetings(for: day, includeInProgress: false)
            .compactMap(latestArtifactWriteAt(for:))
            .max()
        guard let latestArtifactWrite, latestArtifactWrite > completedAt else {
            return completedAt
        }
        return nil
    }
}
