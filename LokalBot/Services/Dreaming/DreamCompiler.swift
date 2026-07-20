import Foundation

/// Everything one dream reads, gathered up front so the synthesis step is a
/// pure function of this value: the analyzed day's meetings with extracted
/// outcomes, the day digest, screen-memory stats, plus a bounded comparison
/// window of prior meetings and still-open action candidates.
struct DreamEvidence: Equatable {
    struct MeetingEvidence: Equatable {
        var shortID: String
        var title: String
        var durationLabel: String
        var startedAt: Date
        var outcomes: MeetingOutcomes
    }

    struct PriorMeeting: Equatable {
        var dayKey: String
        var title: String
    }

    var day: Date
    var dayKey: String
    var digest: String?
    var meetings: [MeetingEvidence]
    var appUsage: [ScreenMemoryAppUsage]
    var stats: ScreenMemoryDaySummary
    var savedMoments: [ScreenMemorySavedMoment]
    /// Meetings from the preceding comparison window (titles + days only),
    /// so the model can spot recurring themes without re-reading transcripts.
    var priorMeetings: [PriorMeeting]
    /// Pre-rendered action-candidate lines from the window, `- [ ] …` style.
    var openActions: [String]
}

/// Deterministic evidence gathering for one dreamed day plus the model-free
/// fallback brief. Read-only over the local library; pure enough that every
/// piece is unit-testable without an engine or a live database.
enum DreamCompiler {
    /// The retrospective looks back at most this many days (the dreamed day
    /// included) for recurring patterns — a comparison window, never new
    /// primary material.
    static let comparisonWindowDays = 14
    static let evidenceCharacterLimit = 24_000
    static let maxOpenActions = 30

    static func compile(day: Date, storageRoot: URL,
                        calendar: Calendar = .current) throws -> DreamEvidence {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start)
            ?? start.addingTimeInterval(86_400)
        let interval = DateInterval(start: start, end: end)
        let snapshot = try FileDailyMemoryExportSource(
            root: storageRoot,
            calendar: calendar).snapshot(
            for: start, interval: interval)
        let all = try SessionLookup.loadAllMeetings(root: storageRoot)

        let dayMeetings = all.filter { interval.contains($0.startedAt) }
            .sorted { $0.startedAt < $1.startedAt }
            .map { meeting in
                DreamEvidence.MeetingEvidence(
                    shortID: SessionLookup.shortID(meeting.id),
                    title: meeting.title,
                    durationLabel: meeting.durationLabel,
                    startedAt: meeting.startedAt,
                    outcomes: outcomes(for: meeting, storageRoot: storageRoot))
            }

        let windowStart = calendar.date(byAdding: .day,
                                        value: -(comparisonWindowDays - 1),
                                        to: start)
            ?? start.addingTimeInterval(TimeInterval(-(comparisonWindowDays - 1) * 86_400))
        let priorMeetings = all.filter { $0.startedAt >= windowStart && $0.startedAt < start }
            .sorted { $0.startedAt < $1.startedAt }
            .map {
                DreamEvidence.PriorMeeting(
                    dayKey: DreamDay.key(for: $0.startedAt, calendar: calendar),
                    title: $0.title)
            }

        let openActions = all.filter { $0.startedAt >= windowStart && $0.startedAt < end }
            .sorted { $0.startedAt > $1.startedAt }
            .flatMap { meeting in
                outcomes(for: meeting, storageRoot: storageRoot).actionItems.map {
                    actionLine($0, shortID: SessionLookup.shortID(meeting.id))
                }
            }

        return DreamEvidence(
            day: start,
            dayKey: DreamDay.key(for: start, calendar: calendar),
            digest: trimmedToNil(snapshot.digest),
            meetings: dayMeetings,
            appUsage: snapshot.appUsage,
            stats: snapshot.stats,
            savedMoments: snapshot.savedMoments,
            priorMeetings: priorMeetings,
            openActions: Array(openActions.prefix(maxOpenActions)))
    }

    /// The prompt material: every evidence section rendered as labeled plain
    /// text, then sanitized and hard-capped like the summarizer's transcript
    /// input so an OCR-heavy day can't blow the context window.
    static func evidencePack(_ evidence: DreamEvidence) -> String {
        var sections: [String] = []

        if evidence.meetings.isEmpty {
            sections.append("Meetings on \(evidence.dayKey): none recorded.")
        } else {
            var lines = ["Meetings on \(evidence.dayKey):"]
            for meeting in evidence.meetings {
                lines.append("- \(clean(meeting.title)) (`\(meeting.shortID)`, \(meeting.durationLabel))")
                lines += meeting.outcomes.decisions.map { "  decision: \(clean($0))" }
                lines += meeting.outcomes.actionItems.map { item in
                    var line = "  action: \(clean(item.text))"
                    if let owner = item.owner, !owner.isEmpty {
                        line += " (owner: \(clean(owner)))"
                    }
                    if let due = item.due, !due.isEmpty {
                        line += " (due: \(clean(due)))"
                    }
                    return line
                }
                lines += meeting.outcomes.openQuestions.map { "  open question: \(clean($0))" }
            }
            sections.append(lines.joined(separator: "\n"))
        }

        if let digest = evidence.digest {
            sections.append("Day digest:\n" + digest)
        }

        if !evidence.appUsage.isEmpty {
            let rows = evidence.appUsage.prefix(10).map {
                "- \(clean($0.app)): \(duration($0.durationSeconds))"
            }
            sections.append("App-time totals:\n" + rows.joined(separator: "\n"))
        }
        sections.append(
            "Day stats: tracked \(duration(evidence.stats.trackedSeconds)) across "
                + "\(evidence.stats.appCount) apps, \(evidence.stats.screenshotCount) context captures.")

        if !evidence.savedMoments.isEmpty {
            let rows = evidence.savedMoments.prefix(10).map { moment -> String in
                let label = moment.windowTitle.isEmpty
                    ? moment.app : "\(moment.app) — \(moment.windowTitle)"
                let note = clean(moment.note)
                return "- \(clean(label))" + (note.isEmpty ? "" : " (note: \(note))")
            }
            sections.append("Saved moments:\n" + rows.joined(separator: "\n"))
        }

        if !evidence.priorMeetings.isEmpty {
            let rows = evidence.priorMeetings.suffix(40).map { "- \($0.dayKey): \(clean($0.title))" }
            sections.append(
                "Meetings in the prior \(comparisonWindowDays - 1) days "
                    + "(comparison window only):\n" + rows.joined(separator: "\n"))
        }

        if !evidence.openActions.isEmpty {
            sections.append(
                "Action candidates from the last \(comparisonWindowDays) days "
                    + "(completion is unknown):\n" + evidence.openActions.joined(separator: "\n"))
        }

        return PromptContextSanitizer.sanitize(
            sections.joined(separator: "\n\n"), maxCharacters: evidenceCharacterLimit)
    }

    /// The model-free brief: only restates evidence — counts, the day's open
    /// questions, and carry-forward action candidates. It never analyzes,
    /// so it can never invent.
    static func fallbackReport(from evidence: DreamEvidence, generatedAt: Date,
                               reason: DreamFallbackReason, note: String) -> DreamReport {
        let meetingCount = evidence.meetings.count
        let meetingPhrase = meetingCount == 1 ? "1 recorded meeting" : "\(meetingCount) recorded meetings"
        let narrative = note + " Yesterday: \(meetingPhrase), "
            + "\(duration(evidence.stats.trackedSeconds)) tracked across "
            + "\(evidence.stats.appCount) apps."

        let attention = evidence.meetings.flatMap { meeting in
            meeting.outcomes.openQuestions.map { "\(clean($0)) — `\(meeting.shortID)`" }
        }

        let userActions = evidence.meetings.flatMap { meeting in
            meeting.outcomes.userActionItems.map {
                actionDescription($0, shortID: meeting.shortID)
                    + " (completion not tracked)"
            }
        }

        return DreamReport(
            day: evidence.dayKey,
            generatedAt: generatedAt,
            engineName: nil,
            fallbackReason: reason,
            narrative: narrative,
            attention: Array(attention.prefix(5)),
            topActions: Array(userActions.prefix(3)))
    }

    private static func outcomes(for meeting: Meeting, storageRoot: URL) -> MeetingOutcomes {
        MeetingOutcomes.load(
            from: storageRoot.appendingPathComponent(meeting.relativePath, isDirectory: true))
            ?? MeetingOutcomes()
    }

    private static func actionLine(_ item: MeetingOutcomes.ActionItem,
                                   shortID: String) -> String {
        "- [ ] " + actionDescription(item, shortID: shortID)
    }

    private static func actionDescription(_ item: MeetingOutcomes.ActionItem,
                                          shortID: String) -> String {
        var suffix: [String] = []
        if let owner = item.owner, !owner.isEmpty { suffix.append("owner: \(clean(owner))") }
        if let due = item.due, !due.isEmpty { suffix.append("due: \(clean(due))") }
        return clean(item.text)
            + (suffix.isEmpty ? "" : " (\(suffix.joined(separator: ", ")))")
            + " — `\(shortID)`"
    }

    private static func clean(_ value: String) -> String {
        value.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
            .replacingOccurrences(of: "`", with: "\\`")
    }

    private static func trimmedToNil(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds.rounded()) / 60)
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}
