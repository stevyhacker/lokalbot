import Foundation

/// One retained, privacy-scrubbed screen-context record used by the day digest.
/// Pixels never enter this value; `text` is the same local Accessibility/OCR
/// text already stored in the screen-memory index.
struct DayScreenContext: Equatable, Sendable {
    var snapshotID: Int64
    var capturedAt: Date
    var app: String
    var windowTitle: String
    var text: String
}

/// Meeting evidence folded into the workday summary without making the day
/// pipeline parse meeting artifacts itself.
struct DayDigestMeetingEvidence: Equatable, Sendable {
    var id: UUID
    var title: String
    var app: String
    var startedAt: Date
    var endedAt: Date
    var sourceSummary: String
    var outcomes: String
    /// Latest write among the summary/outcomes files consumed for this meeting.
    /// It is evidence even when the meeting's own end time is unchanged.
    var artifactModifiedAt: Date?
}

enum DayDigestMeetingArtifacts {
    static let fileNames = ["summary.md", MeetingOutcomes.fileName]

    static func latestModifiedAt(in folder: URL) -> Date? {
        fileNames.compactMap { name -> Date? in
            let url = folder.appendingPathComponent(name)
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            return attributes?[.modificationDate] as? Date
        }.max()
    }
}

/// One deterministic slice of the day that receives a substantive-work
/// eligibility pass. Character pressure may split a long active session, while
/// a real idle gap always starts a new slice. Metadata-only slices stay in the
/// lossless journal without becoming visible summary items.
struct DayDigestSummarySegment: Equatable, Sendable {
    var start: Date
    var end: Date
    var activeDuration: TimeInterval
    var evidence: String
    var eventCount: Int
    var sourceIDs: [Int64]
}

/// Complete, ordered evidence for one local calendar day. The model consumes
/// bounded chunks of this value, while the journal's chronological log is
/// rendered directly so model brevity or failure can never omit activity.
struct DayDigestEvidence: Equatable, Sendable {
    struct Activity: Equatable, Sendable {
        var id: Int64
        var start: Date
        var end: Date
        var app: String
        var title: String
        var contexts: [DayScreenContext]
    }

    var day: Date
    var interval: DateInterval
    var activities: [Activity]
    var standaloneContexts: [DayScreenContext]
    var meetings: [DayDigestMeetingEvidence]

    var isEmpty: Bool {
        activities.isEmpty && standaloneContexts.isEmpty && meetings.isEmpty
    }

    var latestEvidenceAt: Date? {
        let activityEnd = activities.map(\.end).max()
        let contextCapture = standaloneContexts.map(\.capturedAt).max()
        let meetingEnd = meetings.map(\.endedAt).max()
        let meetingArtifact = meetings.compactMap(\.artifactModifiedAt).max()
        return [activityEnd, contextCapture, meetingEnd, meetingArtifact]
            .compactMap { $0 }
            .max()
    }

    static func build(
        day: Date,
        blocks: [ActivityBlock],
        screenContexts: [DayScreenContext],
        meetings: [DayDigestMeetingEvidence],
        calendar: Calendar = .current
    ) -> DayDigestEvidence {
        let interval = ActivityStore.dayInterval(containing: day, calendar: calendar)
        let clipped = blocks.compactMap { block -> Activity? in
            let start = max(block.start, interval.start)
            let end = min(block.end, interval.end)
            guard end > start else { return nil }
            return Activity(id: block.id, start: start, end: end, app: block.app,
                            title: block.title, contexts: [])
        }.sorted { lhs, rhs in
            lhs.start == rhs.start ? lhs.id < rhs.id : lhs.start < rhs.start
        }

        var activities = clipped
        var standalone: [DayScreenContext] = []
        let contexts = deduplicated(screenContexts)
            .filter { interval.contains($0.capturedAt) }
            .sorted { lhs, rhs in
                lhs.capturedAt == rhs.capturedAt
                    ? lhs.snapshotID < rhs.snapshotID
                    : lhs.capturedAt < rhs.capturedAt
            }

        for context in contexts {
            if let index = activities.firstIndex(where: {
                context.capturedAt >= $0.start && context.capturedAt < $0.end
            }) {
                activities[index].contexts.append(context)
            } else {
                standalone.append(context)
            }
        }

        return DayDigestEvidence(
            day: day,
            interval: interval,
            activities: activities,
            standaloneContexts: standalone,
            meetings: meetings.sorted { lhs, rhs in
                lhs.startedAt == rhs.startedAt
                    ? lhs.id.uuidString < rhs.id.uuidString
                    : lhs.startedAt < rhs.startedAt
            })
    }

    /// Full-day evidence for LLM summarization. Every summary-worthy activity
    /// and meeting appears in exactly one segment, and each long block contributes
    /// evenly spaced context in proportion to its duration rather than letting
    /// the morning exhaust a global cap. An idle gap creates a hard boundary,
    /// so short morning work cannot be obscured by an afternoon session.
    func summarySegments(
        maxCharacters: Int = 12_000,
        inactivityGap: TimeInterval = 10 * 60,
        maxSegments: Int = 8
    ) -> [DayDigestSummarySegment] {
        guard maxCharacters > 0, maxSegments > 0 else { return [] }
        let events = summaryEvents()
        guard !events.isEmpty else { return [] }
        var sessions = summarySessions(from: events, inactivityGap: inactivityGap)
        mergeShortestSessions(&sessions, maximumCount: maxSegments)
        let allocations = segmentAllocations(for: sessions, maximumCount: maxSegments)
        let groups = splitSessions(sessions, allocations: allocations)
        return groups.map {
            makeSummarySegment(events: $0, maxCharacters: maxCharacters)
        }
    }

    private func summarySessions(
        from events: [SummaryEvent],
        inactivityGap: TimeInterval
    ) -> [[SummaryEvent]] {
        var sessions: [[SummaryEvent]] = []
        for event in events {
            if belongsToCurrentSession(event, sessions: sessions, inactivityGap: inactivityGap) {
                sessions[sessions.count - 1].append(event)
            } else {
                sessions.append([event])
            }
        }
        return sessions
    }

    private func belongsToCurrentSession(
        _ event: SummaryEvent,
        sessions: [[SummaryEvent]],
        inactivityGap: TimeInterval
    ) -> Bool {
        guard let previousEnd = sessions.last?.map(\.end).max() else { return false }
        return event.start.timeIntervalSince(previousEnd) <= inactivityGap
    }

    private func mergeShortestSessions(
        _ sessions: inout [[SummaryEvent]],
        maximumCount: Int
    ) {
        // Preserve every event while preventing brief interruptions from
        // consuming most of the bounded output.
        while sessions.count > maximumCount {
            let index = shortestAdjacentSessionPair(in: sessions)
            sessions[index].append(contentsOf: sessions.remove(at: index + 1))
        }
    }

    private func shortestAdjacentSessionPair(in sessions: [[SummaryEvent]]) -> Int {
        var bestIndex = 0
        var bestDuration = coveredDuration(of: sessions[0] + sessions[1])
        for index in 1..<(sessions.count - 1) {
            let duration = coveredDuration(of: sessions[index] + sessions[index + 1])
            if duration < bestDuration {
                bestIndex = index
                bestDuration = duration
            }
        }
        return bestIndex
    }

    private func segmentAllocations(
        for sessions: [[SummaryEvent]],
        maximumCount: Int
    ) -> [Int] {
        var allocations = Array(repeating: 1, count: sessions.count)
        while allocations.reduce(0, +) < maximumCount {
            guard let index = nextSessionToSplit(sessions, allocations: allocations) else { break }
            allocations[index] += 1
        }
        return allocations
    }

    private func nextSessionToSplit(
        _ sessions: [[SummaryEvent]],
        allocations: [Int]
    ) -> Int? {
        sessions.indices
            .filter { allocations[$0] < sessions[$0].count }
            .max { lhs, rhs in
                sessionWeight(sessions[lhs]) / Double(allocations[lhs])
                    < sessionWeight(sessions[rhs]) / Double(allocations[rhs])
            }
    }

    private func splitSessions(
        _ sessions: [[SummaryEvent]],
        allocations: [Int]
    ) -> [[SummaryEvent]] {
        sessions.indices.flatMap { index in
            splitSession(sessions[index], count: allocations[index])
        }
    }

    private func splitSession(_ session: [SummaryEvent], count: Int) -> [[SummaryEvent]] {
        (0..<count).compactMap { part in
            let lower = part * session.count / count
            let upper = (part + 1) * session.count / count
            return lower < upper ? Array(session[lower..<upper]) : nil
        }
    }

    /// Compatibility view used by existing callers and tests.
    func summaryChunks(maxCharacters: Int = 12_000) -> [String] {
        summarySegments(maxCharacters: maxCharacters).map(\.evidence)
    }

    func renderDocument(summary: String, calendar: Calendar = .current) -> String {
        let cleanSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let summaryBody = cleanSummary.isEmpty
            ? "_No grounded summary was generated. The chronological log below is complete._"
            : cleanSummary
        return [
            "## Day summary\n\n\(summaryBody)",
            "## Meetings\n\n\(meetingsSection(calendar: calendar))",
            "## Time allocation\n\n\(timeAllocationSection())",
            "## Full activity log\n\n\(chronologicalLog(calendar: calendar))",
        ].joined(separator: "\n\n") + "\n"
    }

    private static func deduplicated(_ contexts: [DayScreenContext]) -> [DayScreenContext] {
        var result: [DayScreenContext] = []
        var previousFingerprint: String?
        for context in contexts.sorted(by: {
            $0.capturedAt == $1.capturedAt
                ? $0.snapshotID < $1.snapshotID
                : $0.capturedAt < $1.capturedAt
        }) {
            let text = PromptContextSanitizer.sanitize(context.text)
            let fingerprint = [context.app.lowercased(), context.windowTitle.lowercased(), text]
                .joined(separator: "\u{1f}")
            guard fingerprint != previousFingerprint else { continue }
            previousFingerprint = fingerprint
            var sanitized = context
            sanitized.text = text
            result.append(sanitized)
        }
        return result
    }

    private func representativeContexts(
        _ contexts: [DayScreenContext],
        limit: Int = 3
    ) -> [DayScreenContext] {
        guard limit > 0 else { return [] }
        guard contexts.count > limit else { return contexts }
        return evenlySpacedIndices(count: contexts.count, limit: limit).map {
            contexts[$0]
        }
    }

    /// A long uninterrupted app/window block used to expose only three screen
    /// samples—the same evidence depth as a five-minute task. Increase breadth
    /// with active duration while keeping excerpts inside a fixed character
    /// budget, so hours of work are represented across their full span.
    private func summaryContexts(for activity: Activity) -> [DayScreenContext] {
        let duration = max(0, activity.end.timeIntervalSince(activity.start))
        let proportionalLimit = Int(ceil(duration / (30 * 60))) + 1
        return representativeContexts(
            activity.contexts,
            limit: min(12, max(2, proportionalLimit)))
    }

    private struct SummaryEvent {
        var start: Date
        var end: Date
        var order: Int
        var text: String
        var sourceIDs: [Int64]
        var app: String
        var title: String
    }

    private func sessionWeight(_ events: [SummaryEvent]) -> Double {
        let duration = coveredDuration(of: events)
        return duration > 0 ? duration : Double(events.count)
    }

    /// Union the recorded intervals so overlapping meeting and app evidence is
    /// not double-counted when deciding how much narrative space a segment gets.
    private func coveredDuration(of events: [SummaryEvent]) -> TimeInterval {
        let intervals = events.compactMap { event -> DateInterval? in
            guard event.end > event.start else { return nil }
            return DateInterval(start: event.start, end: event.end)
        }.sorted { $0.start < $1.start }
        guard var current = intervals.first else { return 0 }
        var total: TimeInterval = 0
        for interval in intervals.dropFirst() {
            if interval.start <= current.end {
                current = DateInterval(
                    start: current.start,
                    end: max(current.end, interval.end))
            } else {
                total += current.duration
                current = interval
            }
        }
        return total + current.duration
    }

    private func summaryEvents() -> [SummaryEvent] {
        var events: [SummaryEvent] = []
        for activity in activities where !isSystemOnlySummaryActivity(app: activity.app) {
            let contexts = summaryContexts(for: activity)
            let perContextBudget = contexts.isEmpty
                ? 0
                : max(360, min(1_200, 8_400 / contexts.count))
            var lines = ["WORK SOURCE: ACTIVITY"]
            if !activity.title.isEmpty {
                lines.append(
                    "Possible task context (weak; corroborate before summarizing): "
                        + activity.title)
            }
            for context in contexts {
                let source = context.snapshotID > 0 ? "[screen:\(context.snapshotID)]" : "[screen]"
                let text = summaryExcerpt(
                    context.text,
                    maxCharacters: perContextBudget)
                if !text.isEmpty {
                    lines.append("Screen context \(source):\n\(text)")
                }
            }
            lines.append(
                "LOW-PRIORITY TRACE METADATA — do not summarize directly:\n"
                    + "\(time(activity.start))–\(time(activity.end)); "
                    + "app=\(activity.app); "
                    + "window=\(activity.title.isEmpty ? "Unknown" : activity.title); "
                    + "duration=\(duration(activity.end.timeIntervalSince(activity.start)))")
            events.append(SummaryEvent(
                start: activity.start,
                end: activity.end,
                order: 1,
                text: lines.joined(separator: "\n"),
                sourceIDs: contexts.map(\.snapshotID).filter { $0 > 0 },
                app: activity.app,
                title: activity.title))
        }
        for context in standaloneContexts where !isSystemOnlySummaryActivity(app: context.app) {
            let source = context.snapshotID > 0 ? "[screen:\(context.snapshotID)]" : "[screen]"
            let text = summaryExcerpt(context.text, maxCharacters: 1_200)
            events.append(SummaryEvent(
                start: context.capturedAt,
                end: context.capturedAt,
                order: 2,
                text: """
                    WORK SOURCE: SCREEN CONTEXT \(source)
                    Captured work text: \(text)
                    LOW-PRIORITY TRACE METADATA — do not summarize directly:
                    \(time(context.capturedAt)); app=\(context.app); window=\(context.windowTitle.isEmpty ? "Unknown" : context.windowTitle)
                    """,
                sourceIDs: context.snapshotID > 0 ? [context.snapshotID] : [],
                app: context.app,
                title: context.windowTitle))
        }
        for meeting in meetings {
            var lines = ["WORK SOURCE: MEETING", "Task context: \(meeting.title)"]
            let sourceSummary = PromptContextSanitizer.sanitize(
                meeting.sourceSummary, maxCharacters: 6_000)
            if !sourceSummary.isEmpty { lines.append("Source summary:\n" + sourceSummary) }
            let outcomes = PromptContextSanitizer.sanitize(
                meeting.outcomes, maxCharacters: 3_000)
            if !outcomes.isEmpty { lines.append("Outcomes:\n" + outcomes) }
            lines.append(
                "LOW-PRIORITY TRACE METADATA — do not summarize directly:\n"
                    + "\(time(meeting.startedAt))–\(time(meeting.endedAt)); "
                    + "app=\(meeting.app)")
            events.append(SummaryEvent(
                start: meeting.startedAt,
                end: meeting.endedAt,
                order: 0,
                text: lines.joined(separator: "\n"),
                sourceIDs: [],
                app: meeting.app,
                title: meeting.title))
        }
        events.sort { lhs, rhs in
            if lhs.start == rhs.start { return lhs.order < rhs.order }
            return lhs.start < rhs.start
        }
        return events
    }

    /// Login transitions are useful in the lossless activity log, but they are
    /// not work topics and should not consume scarce overview space.
    private func isSystemOnlySummaryActivity(app: String) -> Bool {
        app.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("loginwindow") == .orderedSame
    }

    private func makeSummarySegment(
        events: [SummaryEvent],
        maxCharacters: Int
    ) -> DayDigestSummarySegment {
        let detailIndices = summaryDetailIndices(events: events, limit: 12)
        let contentBudget = max(120, Int(Double(maxCharacters) * 0.82))
        let perDetailBudget = max(120, contentBudget / max(1, detailIndices.count))
        let details = detailIndices.map { index in
            PromptContextSanitizer.sanitize(
                events[index].text,
                maxCharacters: perDetailBudget)
        }.filter { !$0.isEmpty }
        var evidence = "WORK CONTENT — primary evidence:\n"
            + details.joined(separator: "\n\n---\n\n")

        let remaining = max(0, maxCharacters - evidence.count - 72)
        if remaining > 80 {
            let perLineBudget = max(48, min(160, remaining / max(1, events.count)))
            let inventoryLines = events.map { event in
                let title = event.title.isEmpty ? "Unknown" : event.title
                return singleLine(
                    "[\(time(event.start))–\(time(event.end))] \(event.app) — \(title)",
                    maxCharacters: perLineBudget)
            }
            evidence += "\n\nLOW-PRIORITY TRACE METADATA — context only, never a work item:\n"
                + inventoryLines.joined(separator: "\n")
        }
        evidence = PromptContextSanitizer.sanitize(
            evidence, maxCharacters: maxCharacters)

        var sourceIDs: [Int64] = []
        for event in events {
            for id in event.sourceIDs where !sourceIDs.contains(id) { sourceIDs.append(id) }
        }
        return DayDigestSummarySegment(
            start: events.first?.start ?? day,
            end: events.map(\.end).max() ?? events.first?.start ?? day,
            activeDuration: coveredDuration(of: events),
            evidence: evidence,
            eventCount: events.count,
            sourceIDs: sourceIDs)
    }

    /// Meetings are already structured work evidence, so a busy interval must
    /// not sample around them merely because it contains many short activity
    /// events. Fill the remaining detail budget evenly across the interval.
    private func summaryDetailIndices(
        events: [SummaryEvent],
        limit: Int
    ) -> [Int] {
        guard !events.isEmpty, limit > 0 else { return [] }
        let meetingIndices = events.indices.filter { events[$0].order == 0 }
        if meetingIndices.count >= limit {
            return evenlySpacedIndices(count: meetingIndices.count, limit: limit)
                .map { meetingIndices[$0] }
        }

        let remainingIndices = events.indices.filter { events[$0].order != 0 }
        let remainingLimit = min(limit - meetingIndices.count, remainingIndices.count)
        let sampled = evenlySpacedIndices(
            count: remainingIndices.count,
            limit: remainingLimit
        ).map { remainingIndices[$0] }
        return (meetingIndices + sampled).sorted()
    }

    private func evenlySpacedIndices(count: Int, limit: Int) -> [Int] {
        guard count > 0, limit > 0 else { return [] }
        if limit == 1 { return [0] }
        if count <= limit { return Array(0..<count) }
        let denominator = Double(limit - 1)
        var result: [Int] = []
        for index in 0..<limit {
            let position = Int((Double(index) * Double(count - 1) / denominator).rounded())
            if !result.contains(position) { result.append(position) }
        }
        return result
    }

    private func chronologicalLog(calendar: Calendar) -> String {
        enum Event {
            case activity(Activity)
            case context(DayScreenContext)
            case meeting(DayDigestMeetingEvidence)

            var date: Date {
                switch self {
                case .activity(let value): value.start
                case .context(let value): value.capturedAt
                case .meeting(let value): value.startedAt
                }
            }

            var order: Int {
                switch self {
                case .meeting: 0
                case .activity: 1
                case .context: 2
                }
            }
        }

        var events = activities.map(Event.activity)
        events += standaloneContexts.map(Event.context)
        events += meetings.map(Event.meeting)
        events.sort { lhs, rhs in
            lhs.date == rhs.date ? lhs.order < rhs.order : lhs.date < rhs.date
        }
        guard !events.isEmpty else { return "_No activity was recorded._" }

        return events.map { event in
            switch event {
            case .activity(let activity):
                var line = "- **\(time(activity.start, calendar: calendar))–"
                    + "\(time(activity.end, calendar: calendar))** — "
                    + "**\(markdownInline(activity.app))**"
                if !activity.title.isEmpty {
                    line += " — \(markdownInline(activity.title))"
                }
                for context in representativeContexts(activity.contexts) {
                    let excerpt = singleLine(context.text, maxCharacters: 360)
                    guard !excerpt.isEmpty else { continue }
                    let source = context.snapshotID > 0
                        ? "[screen:\(context.snapshotID)]" : "screen context"
                    line += "\n  - \(source), \(time(context.capturedAt, calendar: calendar)): "
                        + markdownInline(excerpt)
                }
                return line
            case .context(let context):
                let title = context.windowTitle.isEmpty
                    ? markdownInline(context.app)
                    : "\(markdownInline(context.app)) — \(markdownInline(context.windowTitle))"
                let source = context.snapshotID > 0
                    ? "[screen:\(context.snapshotID)]" : "screen context"
                let excerpt = singleLine(context.text, maxCharacters: 360)
                return "- **\(time(context.capturedAt, calendar: calendar))** — "
                    + "**Screen context** — \(title)\n  - \(source): \(markdownInline(excerpt))"
            case .meeting(let meeting):
                return "- **\(time(meeting.startedAt, calendar: calendar))–"
                    + "\(time(meeting.endedAt, calendar: calendar))** — **Meeting** — "
                    + "\(markdownInline(meeting.title)) (\(markdownInline(meeting.app)))"
            }
        }.joined(separator: "\n")
    }

    private func meetingsSection(calendar: Calendar) -> String {
        guard !meetings.isEmpty else { return "_None._" }
        return meetings.map { meeting in
            var lines = [
                "### \(time(meeting.startedAt, calendar: calendar)) — \(markdownInline(meeting.title))",
                "- App: \(markdownInline(meeting.app))",
                "- Duration: \(duration(meeting.endedAt.timeIntervalSince(meeting.startedAt)))",
            ]
            let summary = singleLine(meeting.sourceSummary, maxCharacters: 600)
            if !summary.isEmpty { lines.append("- Source summary: \(markdownInline(summary))") }
            let outcomes = singleLine(meeting.outcomes, maxCharacters: 400)
            if !outcomes.isEmpty { lines.append("- Outcomes: \(markdownInline(outcomes))") }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    private func timeAllocationSection() -> String {
        let activitiesByApp: [String: [Activity]] = Dictionary(
            grouping: activities,
            by: { activity in activity.app }
        )
        var totals: [(app: String, seconds: TimeInterval)] = []
        totals.reserveCapacity(activitiesByApp.count)
        for (app, appActivities) in activitiesByApp {
            var seconds: TimeInterval = 0
            for activity in appActivities {
                seconds += activity.end.timeIntervalSince(activity.start)
            }
            totals.append((app: app, seconds: seconds))
        }
        totals.sort { lhs, rhs in
            lhs.seconds == rhs.seconds ? lhs.app < rhs.app : lhs.seconds > rhs.seconds
        }
        guard !totals.isEmpty else { return "_No tracked app time._" }
        var lines = ["| App | Tracked time |", "| --- | ---: |"]
        lines += totals.map { app, seconds in
            "| \(markdownTable(app)) | \(duration(seconds)) |"
        }
        return lines.joined(separator: "\n")
    }

    /// Remove recurring Accessibility chrome only from the model-facing
    /// excerpt. The deterministic journal below retains the original scrubbed
    /// evidence verbatim, including source IDs, for inspection and export.
    private func summaryExcerpt(_ value: String, maxCharacters: Int) -> String {
        var result = PromptContextSanitizer.sanitize(value)
        let recurringChrome = [
            "this button also has an action to zoom the window",
            "Bookmarks New Tab Back Forward Reload",
            "Chrome Apps Saved Tab Groups Separator",
            "Hide sidebar Back Forward Chat actions",
            "Toggle pinned summary Toggle bottom panel Toggle side panel",
        ]
        for phrase in recurringChrome {
            result = result.replacingOccurrences(
                of: phrase, with: "", options: .caseInsensitive)
        }
        return PromptContextSanitizer.sanitize(result, maxCharacters: maxCharacters)
    }

    private func time(_ date: Date, calendar: Calendar = .current) -> String {
        LocalDateFormatting.time(date, calendar: calendar)
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds.rounded()) / 60)
        if minutes == 0 { return "<1m" }
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes)m"
    }

    private func singleLine(_ value: String, maxCharacters: Int) -> String {
        PromptContextSanitizer.sanitize(value, maxCharacters: maxCharacters)
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
    }

    private func markdownInline(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "_", with: "\\_")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }

    private func markdownTable(_ value: String) -> String {
        markdownInline(value).replacingOccurrences(of: "|", with: "\\|")
    }
}


struct DayDigestGenerationMetadata: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    var quality: DayDigestGenerationQuality
    var generatedAt: Date
    var journalModifiedAt: Date
    var evidenceLatestAt: Date?
    var degradedAttemptCount: Int
}

enum DayDigestGenerationMetadataStore {
    static let maximumDegradedAttempts = 3

    static func metadataURL(for journalURL: URL) -> URL {
        journalURL.deletingPathExtension().appendingPathExtension("meta.json")
    }

    static func load(for journalURL: URL) -> DayDigestGenerationMetadata? {
        let url = metadataURL(for: journalURL)
        guard let data = try? Data(contentsOf: url),
              let metadata = try? JSONDecoder().decode(
                DayDigestGenerationMetadata.self,
                from: data),
              metadata.version == DayDigestGenerationMetadata.currentVersion
        else { return nil }
        return metadata
    }

    /// Records whether this journal still needs a model-backed repair. Repeated
    /// degraded writes for unchanged evidence increment a durable budget so a
    /// persistently crashing model cannot be relaunched forever.
    @discardableResult
    static func record(
        quality: DayDigestGenerationQuality,
        evidenceLatestAt: Date?,
        for journalURL: URL,
        generatedAt: Date = Date()
    ) throws -> DayDigestGenerationMetadata {
        let previous = load(for: journalURL)
        let sameEvidence = previous?.evidenceLatestAt == evidenceLatestAt
        let degradedAttemptCount: Int
        if quality.needsRepair {
            let previousCount = previous?.quality.needsRepair == true && sameEvidence
                ? previous?.degradedAttemptCount ?? 0
                : 0
            degradedAttemptCount = min(
                maximumDegradedAttempts,
                previousCount + 1)
        } else {
            degradedAttemptCount = 0
        }
        let attributes = try FileManager.default.attributesOfItem(
            atPath: journalURL.path)
        let journalModifiedAt = attributes[.modificationDate] as? Date ?? generatedAt
        let metadata = DayDigestGenerationMetadata(
            version: DayDigestGenerationMetadata.currentVersion,
            quality: quality,
            generatedAt: generatedAt,
            journalModifiedAt: journalModifiedAt,
            evidenceLatestAt: evidenceLatestAt,
            degradedAttemptCount: degradedAttemptCount)
        let data = try JSONEncoder().encode(metadata)
        try data.write(to: metadataURL(for: journalURL), options: .atomic)
        return metadata
    }

    /// Legacy or externally edited journals keep their modification-time
    /// semantics. A matching degraded sidecar returns nil while a bounded quiet
    /// repair is still eligible, making the scheduler treat it as unfinished.
    static func completedAt(for journalURL: URL) -> Date? {
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: journalURL.path),
              let modifiedAt = attributes[.modificationDate] as? Date
        else { return nil }
        guard let metadata = load(for: journalURL) else { return modifiedAt }
        let sidecarMatchesJournal = abs(
            metadata.journalModifiedAt.timeIntervalSince(modifiedAt)) < 0.5
        guard sidecarMatchesJournal else { return modifiedAt }
        if metadata.quality.needsRepair,
           metadata.degradedAttemptCount < maximumDegradedAttempts {
            return nil
        }
        return modifiedAt
    }
}

enum DayDigestFreshness {
    static func isStale(digestModifiedAt: Date?, latestEvidenceAt: Date?) -> Bool {
        guard let digestModifiedAt, let latestEvidenceAt else { return false }
        return latestEvidenceAt > digestModifiedAt
    }
}

struct DayDigestGenerationResult {
    var text: String
    var url: URL
    var quality: DayDigestGenerationQuality
}
