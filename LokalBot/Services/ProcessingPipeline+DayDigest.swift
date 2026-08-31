import Foundation

extension ProcessingPipeline {
    /// Shared by the Timeline UI, scheduler, and `--digest`. The model writes
    /// only the task-first overview; code retains the chronological evidence.
    func generateDayDigest(
        for day: Date,
        blocks: [ActivityBlock],
        meetings: [Meeting],
        screenContexts: [DayScreenContext],
        config: AppSettings
    ) async throws -> DayDigestGenerationResult {
        let evidence = DayDigestEvidence.build(
            day: day,
            blocks: blocks,
            screenContexts: screenContexts,
            meetings: dayMeetingEvidence(meetings))
        let overview = try await dayDigestOverview(evidence: evidence, config: config)

        try Task.checkCancellation()
        let text = evidence.renderDocument(summary: overview.summary)
        let name = DreamDay.key(for: day)
        let url = storage.rootURL.appendingPathComponent("journal/\(name).md")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try DayDigestGenerationMetadataStore.record(
            quality: overview.quality,
            evidenceLatestAt: evidence.latestEvidenceAt,
            for: url)
        return DayDigestGenerationResult(text: text, url: url, quality: overview.quality)
    }

    private func dayDigestOverview(
        evidence: DayDigestEvidence,
        config: AppSettings
    ) async throws -> DayDigestOverviewGeneration {
        guard !evidence.isEmpty else {
            return DayDigestOverviewGeneration(
                summary: DayDigestOverviewGenerator.fallback(evidence),
                quality: .complete)
        }
        do {
            try Task.checkCancellation()
            let engine = try await thinkExecution.makeTextEngine(config, purpose: "day digest")
            return try await DayDigestOverviewGenerator.generateResult(
                evidence: evidence,
                engine: engine,
                customPrompt: config.dayDigestCustomPrompt)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            lokalbotLog("day digest overview fallback error=\(error.localizedDescription)")
            return DayDigestOverviewGeneration(
                summary: DayDigestOverviewGenerator.fallback(evidence),
                quality: .fallback)
        }
    }

    private func dayMeetingEvidence(_ meetings: [Meeting]) -> [DayDigestMeetingEvidence] {
        meetings.compactMap { meeting in
            guard let endedAt = meeting.endedAt else { return nil }
            let folder = meeting.folderURL(in: storage)
            let sourceSummary = (try? String(
                contentsOf: folder.appendingPathComponent("summary.md"),
                encoding: .utf8)) ?? ""
            let outcomes = MeetingOutcomes.load(from: folder).map(Self.renderOutcomes) ?? ""
            return DayDigestMeetingEvidence(
                id: meeting.id,
                title: meeting.title,
                app: meeting.appName,
                startedAt: meeting.startedAt,
                endedAt: endedAt,
                sourceSummary: sourceSummary,
                outcomes: outcomes,
                artifactModifiedAt: DayDigestMeetingArtifacts.latestModifiedAt(in: folder))
        }
    }

    private nonisolated static func renderOutcomes(_ outcomes: MeetingOutcomes) -> String {
        var lines: [String] = []
        if !outcomes.actionItems.isEmpty {
            lines.append("Action items:")
            lines += outcomes.actionItems.map(renderActionItem)
        }
        if !outcomes.decisions.isEmpty {
            lines.append("Decisions:")
            lines += outcomes.decisions.map { "- \($0)" }
        }
        if !outcomes.openQuestions.isEmpty {
            lines.append("Open questions:")
            lines += outcomes.openQuestions.map { "- \($0)" }
        }
        return lines.joined(separator: "\n")
    }

    private nonisolated static func renderActionItem(
        _ item: MeetingOutcomes.ActionItem
    ) -> String {
        var details: [String] = []
        if let owner = item.owner, !owner.isEmpty { details.append("owner: \(owner)") }
        if let due = item.due, !due.isEmpty { details.append("due: \(due)") }
        let suffix = details.isEmpty ? "" : " (\(details.joined(separator: ", ")))"
        return "- " + item.text + suffix
    }
}
