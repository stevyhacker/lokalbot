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
}

/// One deterministic slice of the day that must receive a visible focus
/// summary. Character pressure may split a long active session, while a real
/// idle gap always starts a new slice. The model can describe a slice but
/// cannot silently remove it from the digest.
struct DayDigestSummarySegment: Equatable, Sendable {
    var start: Date
    var end: Date
    var activeDuration: TimeInterval
    var shareOfRecordedTime: Double
    var isPrimary: Bool
    var evidence: String
    var eventCount: Int
    var sourceIDs: [Int64]
    var apps: [String]
    var titles: [String]
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

        var sessions: [[SummaryEvent]] = []
        for event in events {
            if let previousEnd = sessions.last?.map(\.end).max(),
               event.start.timeIntervalSince(previousEnd) <= inactivityGap {
                sessions[sessions.count - 1].append(event)
            } else {
                sessions.append([event])
            }
        }

        // More than eight isolated sessions are rare, but merging the shortest
        // adjacent pair preserves every event without letting a few brief
        // interruptions consume most of the bounded UI.
        while sessions.count > maxSegments {
            var smallestIndex = 0
            var smallestDuration = coveredDuration(
                of: sessions[0] + sessions[1])
            if sessions.count > 2 {
                for index in 1..<(sessions.count - 1) {
                    let combinedDuration = coveredDuration(
                        of: sessions[index] + sessions[index + 1])
                    if combinedDuration < smallestDuration {
                        smallestIndex = index
                        smallestDuration = combinedDuration
                    }
                }
            }
            sessions[smallestIndex].append(
                contentsOf: sessions.remove(at: smallestIndex + 1))
        }

        var allocations = Array(repeating: 1, count: sessions.count)
        while allocations.reduce(0, +) < maxSegments {
            let candidates = sessions.indices.filter {
                allocations[$0] < sessions[$0].count
            }
            guard let index = candidates.max(by: { lhs, rhs in
                sessionWeight(sessions[lhs]) / Double(allocations[lhs])
                    < sessionWeight(sessions[rhs]) / Double(allocations[rhs])
            }) else { break }
            allocations[index] += 1
        }

        var groups: [[SummaryEvent]] = []
        for index in sessions.indices {
            let session = sessions[index]
            let count = allocations[index]
            for part in 0..<count {
                let lower = part * session.count / count
                let upper = (part + 1) * session.count / count
                if lower < upper { groups.append(Array(session[lower..<upper])) }
            }
        }
        let segments = groups.map {
            makeSummarySegment(events: $0, maxCharacters: maxCharacters)
        }
        return applyingProminence(to: segments)
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

    /// Main sessions must account for at least half of the recorded day. A segment is
    /// initially prominent when it represents at least 30 minutes or 10% of
    /// tracked time; the longest remaining segments are promoted until the
    /// main set covers at least 50%. Everything else remains available as
    /// lower-hierarchy activity instead of competing equally for attention.
    private func applyingProminence(
        to input: [DayDigestSummarySegment]
    ) -> [DayDigestSummarySegment] {
        guard !input.isEmpty else { return [] }
        var segments = input
        let total = segments.reduce(0) { $0 + $1.activeDuration }
        guard total > 0 else {
            let equalShare = 1 / Double(segments.count)
            for index in segments.indices {
                segments[index].shareOfRecordedTime = equalShare
                segments[index].isPrimary = true
            }
            return segments
        }

        for index in segments.indices {
            let share = segments[index].activeDuration / total
            segments[index].shareOfRecordedTime = share
            segments[index].isPrimary = segments[index].activeDuration >= 30 * 60
                || share >= 0.10
        }

        var primaryDuration = segments.reduce(0) {
            $0 + ($1.isPrimary ? $1.activeDuration : 0)
        }
        let targetDuration = total * 0.50
        let remaining = segments.indices
            .filter { !segments[$0].isPrimary }
            .sorted {
                if segments[$0].activeDuration == segments[$1].activeDuration {
                    return segments[$0].start < segments[$1].start
                }
                return segments[$0].activeDuration > segments[$1].activeDuration
            }
        for index in remaining where primaryDuration < targetDuration {
            segments[index].isPrimary = true
            primaryDuration += segments[index].activeDuration
        }
        if !segments.contains(where: \.isPrimary),
           let longest = segments.indices.max(by: {
               segments[$0].activeDuration < segments[$1].activeDuration
           }) {
            segments[longest].isPrimary = true
        }
        return segments
    }

    private func summaryEvents() -> [SummaryEvent] {
        var events: [SummaryEvent] = []
        for activity in activities where !isSystemOnlySummaryActivity(app: activity.app) {
            let contexts = summaryContexts(for: activity)
            let perContextBudget = contexts.isEmpty
                ? 0
                : max(360, min(1_200, 8_400 / contexts.count))
            var lines = [
                "[\(time(activity.start))–\(time(activity.end))] ACTIVITY",
                "App: \(activity.app)",
                "Window: \(activity.title.isEmpty ? "Unknown" : activity.title)",
                "Duration: \(duration(activity.end.timeIntervalSince(activity.start)))",
            ]
            for context in contexts {
                let source = context.snapshotID > 0 ? "[screen:\(context.snapshotID)]" : "[screen]"
                let text = summaryExcerpt(
                    context.text,
                    maxCharacters: perContextBudget)
                if !text.isEmpty {
                    lines.append("Screen context \(source) at \(time(context.capturedAt)):\n\(text)")
                }
            }
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
                    [\(time(context.capturedAt))] SCREEN CONTEXT \(source)
                    App: \(context.app)
                    Window: \(context.windowTitle.isEmpty ? "Unknown" : context.windowTitle)
                    Captured text: \(text)
                    """,
                sourceIDs: context.snapshotID > 0 ? [context.snapshotID] : [],
                app: context.app,
                title: context.windowTitle))
        }
        for meeting in meetings {
            var lines = [
                "[\(time(meeting.startedAt))–\(time(meeting.endedAt))] MEETING",
                "Title: \(meeting.title)",
                "App: \(meeting.app)",
            ]
            let sourceSummary = PromptContextSanitizer.sanitize(
                meeting.sourceSummary, maxCharacters: 6_000)
            if !sourceSummary.isEmpty { lines.append("Source summary:\n" + sourceSummary) }
            let outcomes = PromptContextSanitizer.sanitize(
                meeting.outcomes, maxCharacters: 3_000)
            if !outcomes.isEmpty { lines.append("Outcomes:\n" + outcomes) }
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
        let inventoryBudget = max(96, Int(Double(maxCharacters) * 0.58))
        let perLineBudget = max(48, min(220, inventoryBudget / max(1, events.count)))
        let inventoryLines = events.map { event in
            let title = event.title.isEmpty ? "Unknown" : event.title
            return singleLine(
                "[\(time(event.start))–\(time(event.end))] \(event.app) — \(title)",
                maxCharacters: perLineBudget)
        }
        var evidence = "Chronological event inventory:\n"
            + inventoryLines.joined(separator: "\n")

        let detailIndices = evenlySpacedIndices(count: events.count, limit: 8)
        let remaining = max(0, maxCharacters - evidence.count - 28)
        if remaining > 80, !detailIndices.isEmpty {
            let perDetailBudget = max(80, remaining / detailIndices.count)
            let details = detailIndices.map { index in
                PromptContextSanitizer.sanitize(
                    events[index].text,
                    maxCharacters: perDetailBudget)
            }.filter { !$0.isEmpty }
            if !details.isEmpty {
                evidence += "\n\nRepresentative evidence:\n"
                    + details.joined(separator: "\n\n---\n\n")
            }
        }
        evidence = PromptContextSanitizer.sanitize(
            evidence, maxCharacters: maxCharacters)

        var sourceIDs: [Int64] = []
        var apps: [String] = []
        var titles: [String] = []
        for event in events {
            for id in event.sourceIDs where !sourceIDs.contains(id) { sourceIDs.append(id) }
            if !event.app.isEmpty, !apps.contains(event.app) { apps.append(event.app) }
            if !event.title.isEmpty, !titles.contains(event.title) { titles.append(event.title) }
        }
        return DayDigestSummarySegment(
            start: events.first?.start ?? day,
            end: events.map(\.end).max() ?? events.first?.start ?? day,
            activeDuration: coveredDuration(of: events),
            shareOfRecordedTime: 0,
            isPrimary: false,
            evidence: evidence,
            eventCount: events.count,
            sourceIDs: sourceIDs,
            apps: apps,
            titles: titles)
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
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
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

struct DayDigestGeneratedFocusBlock: Equatable, Sendable {
    var start: Date
    var end: Date
    var activeDuration: TimeInterval
    var shareOfRecordedTime: Double
    var isPrimary: Bool
    var topic: String
    var summary: String
    var sourceIDs: [Int64]
}

/// Converts deterministic, gap-aware evidence segments into the compact
/// human layer shown above the lossless journal. The model writes wording for
/// every segment; code owns the segment count, time ranges, citations, and
/// final Markdown hierarchy so no synthesis pass can erase most of the day.
enum DayDigestOverviewGenerator {
    private struct FocusDraft: Decodable {
        var topic: String
        var summary: String
        var sourceIDs: [Int64]?

        enum CodingKeys: String, CodingKey {
            case topic
            case summary
            case sourceIDs = "source_ids"
        }
    }

    private struct HighlightsDraft: Decodable {
        struct Highlight: Decodable {
            var blockIndex: Int
            var text: String

            enum CodingKeys: String, CodingKey {
                case blockIndex = "block_index"
                case text
            }
        }

        var atAGlance: [Highlight]
        var decisionsAndNextSteps: [String]

        enum CodingKeys: String, CodingKey {
            case atAGlance = "at_a_glance"
            case decisionsAndNextSteps = "decisions_and_next_steps"
        }
    }

    static func generate(
        evidence: DayDigestEvidence,
        engine: TextEngine,
        customPrompt: String,
        calendar: Calendar = .current
    ) async throws -> String {
        let segments = evidence.summarySegments()
        guard !segments.isEmpty else { return fallback(evidence, calendar: calendar) }
        let ranges = segments.map {
            "\(time($0.start, calendar: calendar))-\(time($0.end, calendar: calendar))"
        }.joined(separator: ",")
        lokalbotLog(
            "day digest plan model=\(engine.displayName) segments=\(segments.count) "
                + "events=\(segments.reduce(0) { $0 + $1.eventCount }) ranges=\(ranges)")

        let dateContext = [
            "Date: \(evidence.day.formatted(date: .complete, time: .omitted))",
        ]
        var blocks: [DayDigestGeneratedFocusBlock] = []
        blocks.reserveCapacity(segments.count)

        for (index, segment) in segments.enumerated() {
            try Task.checkCancellation()
            let startedAt = Date()
            let focusPrompt = """
                Summarize required coverage segment \(index + 1) of \(segments.count).
                Exact time range: \(time(segment.start, calendar: calendar))–\(time(segment.end, calendar: calendar))
                Active recorded time: \(compactDuration(segment.activeDuration))
                Share of recorded day: \(Int((segment.shareOfRecordedTime * 100).rounded()))%
                Narrative prominence: \(segment.isPrimary ? "primary work" : "secondary activity")
                Summary limit: \(segment.isPrimary ? 36 : 14) words
                Recorded events: \(segment.eventCount)
                Allowed screen source IDs: \(segment.sourceIDs)

                \(segment.evidence)
                """
            var output = try await engine.generate(
                system: PromptTemplates.dayDigestFocusSystem,
                prompt: focusPrompt,
                context: dateContext,
                schema: focusSchema,
                options: TextGenerationOptions(
                    maxTokens: 768,
                    reasoningBudgetTokens: 256,
                    temperature: 0.2))
            var parsed = parseFocus(output, segment: segment)
            var attempts = 1
            if parsed == nil,
               ProcessInfo.processInfo.environment["LOKALBOT_DIGEST_DEBUG_OUTPUT"] == "1" {
                let preview = PromptContextSanitizer.sanitize(output, maxCharacters: 800)
                lokalbotLog("day digest parse preview index=\(index + 1): \(preview)")
            }
            if parsed == nil {
                attempts = 2
                let retryStartedAt = Date()
                do {
                    output = try await engine.generate(
                        system: PromptTemplates.dayDigestFocusSystem,
                        prompt: "The previous response failed JSON validation. Retry once.\n\n"
                            + focusPrompt,
                        context: dateContext,
                        schema: focusSchema,
                        options: TextGenerationOptions(
                            maxTokens: 1_200,
                            reasoningBudgetTokens: 256,
                            temperature: 0))
                    parsed = parseFocus(output, segment: segment)
                    if parsed == nil,
                       ProcessInfo.processInfo.environment["LOKALBOT_DIGEST_DEBUG_OUTPUT"] == "1" {
                        let preview = PromptContextSanitizer.sanitize(
                            output, maxCharacters: 800)
                        lokalbotLog(
                            "day digest retry parse preview index=\(index + 1): \(preview)")
                    }
                    lokalbotLog(
                        "day digest segment retry index=\(index + 1) parsed=\(parsed != nil) "
                            + "elapsed="
                            + String(format: "%.2fs", Date().timeIntervalSince(retryStartedAt)))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    lokalbotLog(
                        "day digest segment retry index=\(index + 1) error="
                            + error.localizedDescription)
                }
            }
            blocks.append(parsed ?? fallbackBlock(segment))
            lokalbotLog(
                "day digest segment index=\(index + 1)/\(segments.count) "
                    + "events=\(segment.eventCount) chars=\(segment.evidence.count) "
                    + "parsed=\(parsed != nil) attempts=\(attempts) elapsed="
                    + String(format: "%.2fs", Date().timeIntervalSince(startedAt)))
        }

        let highlights: HighlightsDraft?
        let highlightStartedAt = Date()
        do {
            let primaryMaterial = blocks.enumerated()
                .filter { $0.element.isPrimary }
                .map { focusMaterial($0.element, index: $0.offset, calendar: calendar) }
                .joined(separator: "\n")
            let secondaryMaterial = blocks.enumerated()
                .filter { !$0.element.isPrimary }
                .map { focusMaterial($0.element, index: $0.offset, calendar: calendar) }
                .joined(separator: "\n")
            let output = try await engine.generate(
                system: PromptTemplates.dayDigestSystem(custom: customPrompt),
                prompt: """
                    Select the highest-signal highlights in proportion to recorded time.
                    Only PRIMARY blocks are eligible for at_a_glance. Return each highlight with
                    that block's exact index. SECONDARY blocks may inform explicit decisions or
                    next steps, but must not become at_a_glance highlights.

                    PRIMARY BLOCKS:
                    \(primaryMaterial.isEmpty ? "- None" : primaryMaterial)

                    SECONDARY BLOCKS:
                    \(secondaryMaterial.isEmpty ? "- None" : secondaryMaterial)
                    """,
                context: dateContext,
                schema: highlightsSchema,
                options: TextGenerationOptions(
                    maxTokens: 1_200,
                    reasoningBudgetTokens: 512,
                    temperature: 0.2))
            highlights = parseHighlights(output)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            lokalbotLog(
                "day digest highlights fallback error=\(error.localizedDescription)")
            highlights = nil
        }
        lokalbotLog(
            "day digest highlights parsed=\(highlights != nil) elapsed="
                + String(format: "%.2fs", Date().timeIntervalSince(highlightStartedAt)))

        return render(
            blocks: blocks,
            highlights: highlights,
            calendar: calendar)
    }

    static func fallback(
        _ evidence: DayDigestEvidence,
        calendar: Calendar = .current
    ) -> String {
        let blocks = evidence.summarySegments().map(fallbackBlock)
        guard !blocks.isEmpty else {
            return "### At a glance\n- No activity was recorded.\n\n"
                + "### Focus blocks\n- None recorded."
        }
        return render(blocks: blocks, highlights: nil, calendar: calendar)
    }

    private static var focusSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "topic": ["type": "string"],
                "summary": ["type": "string"],
                "source_ids": [
                    "type": "array",
                    "items": ["type": "integer"],
                ],
            ],
            "required": ["topic", "summary", "source_ids"],
            "additionalProperties": false,
        ]
    }

    private static var highlightsSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "at_a_glance": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "block_index": ["type": "integer"],
                            "text": ["type": "string"],
                        ],
                        "required": ["block_index", "text"],
                        "additionalProperties": false,
                    ],
                    "minItems": 1,
                    "maxItems": 3,
                ],
                "decisions_and_next_steps": [
                    "type": "array",
                    "items": ["type": "string"],
                    "maxItems": 4,
                ],
            ],
            "required": ["at_a_glance", "decisions_and_next_steps"],
            "additionalProperties": false,
        ]
    }

    private static func parseFocus(
        _ output: String,
        segment: DayDigestSummarySegment
    ) -> DayDigestGeneratedFocusBlock? {
        guard let json = ChatPrompt.extractJSONObject(strippingReasoning(output)),
              let data = json.data(using: .utf8),
              let draft = try? JSONDecoder().decode(FocusDraft.self, from: data) else {
            return nil
        }
        let topic = cleanInline(draft.topic, maxCharacters: 72)
        let summary = cleanSummary(
            draft.summary,
            maxWords: segment.isPrimary ? 36 : 14)
        guard !topic.isEmpty, !summary.isEmpty else { return nil }
        let allowed = Set(segment.sourceIDs)
        var sourceIDs: [Int64] = []
        for id in draft.sourceIDs ?? [] where allowed.contains(id) && !sourceIDs.contains(id) {
            sourceIDs.append(id)
            if sourceIDs.count == 2 { break }
        }
        return DayDigestGeneratedFocusBlock(
            start: segment.start,
            end: segment.end,
            activeDuration: segment.activeDuration,
            shareOfRecordedTime: segment.shareOfRecordedTime,
            isPrimary: segment.isPrimary,
            topic: topic,
            summary: summary,
            sourceIDs: sourceIDs)
    }

    private static func parseHighlights(_ output: String) -> HighlightsDraft? {
        guard let json = ChatPrompt.extractJSONObject(strippingReasoning(output)),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(HighlightsDraft.self, from: data)
    }

    private static func fallbackBlock(
        _ segment: DayDigestSummarySegment
    ) -> DayDigestGeneratedFocusBlock {
        let meaningfulTitle = segment.titles.first(where: {
            let normalized = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return !normalized.isEmpty && normalized.caseInsensitiveCompare("New Tab") != .orderedSame
        })
        let topic = cleanInline(
            meaningfulTitle ?? segment.apps.first ?? "Recorded work",
            maxCharacters: 72)
        let apps = segment.apps.prefix(3).joined(separator: ", ")
        let summary = segment.eventCount == 1
            ? "One recorded activity event in \(apps.isEmpty ? "this interval" : apps)."
            : "\(segment.eventCount) recorded activity events across "
                + (apps.isEmpty ? "this interval." : "\(apps).")
        return DayDigestGeneratedFocusBlock(
            start: segment.start,
            end: segment.end,
            activeDuration: segment.activeDuration,
            shareOfRecordedTime: segment.shareOfRecordedTime,
            isPrimary: segment.isPrimary,
            topic: topic.isEmpty ? "Recorded work" : topic,
            summary: summary,
            sourceIDs: Array(segment.sourceIDs.prefix(1)))
    }

    private static func render(
        blocks: [DayDigestGeneratedFocusBlock],
        highlights: HighlightsDraft?,
        calendar: Calendar
    ) -> String {
        let normalized = normalizedHighlights(highlights, blocks: blocks)
        let primaryBlocks = blocks.filter(\.isPrimary)
        let secondaryBlocks = blocks.filter { !$0.isPrimary }
        var sections = [
            "### At a glance\n" + normalized.bullets.map { "- \($0)" }.joined(separator: "\n"),
            "### Focus blocks\n" + primaryBlocks.map {
                renderedBlock($0, calendar: calendar)
            }.joined(separator: "\n"),
        ]
        if !secondaryBlocks.isEmpty {
            sections.append(
                "### Other activity\n" + secondaryBlocks.map {
                    renderedBlock($0, calendar: calendar)
                }.joined(separator: "\n"))
        }
        if !normalized.decisions.isEmpty {
            sections.append(
                "### Decisions and next steps\n"
                    + normalized.decisions.map { "- \($0)" }.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }

    private static func normalizedHighlights(
        _ draft: HighlightsDraft?,
        blocks: [DayDigestGeneratedFocusBlock]
    ) -> (bullets: [String], decisions: [String]) {
        let primaryIndices = Set(blocks.indices.filter { blocks[$0].isPrimary })
        var bullets: [String] = []
        for highlight in draft?.atAGlance ?? [] where primaryIndices.contains(highlight.blockIndex) {
            let clean = cleanBullet(highlight.text, maxWords: 38)
            if !clean.isEmpty && !bullets.contains(clean) { bullets.append(clean) }
            if bullets.count == 3 { break }
        }
        if bullets.isEmpty,
           let block = blocks.filter(\.isPrimary).max(by: {
               if $0.activeDuration == $1.activeDuration {
                   return $0.start > $1.start
               }
               return $0.activeDuration < $1.activeDuration
           }) {
            let fallback = cleanBullet("\(block.topic): \(block.summary)", maxWords: 38)
            if !fallback.isEmpty { bullets = [fallback] }
        }
        if bullets.isEmpty { bullets = ["No high-signal activity summary was available."] }

        var decisions: [String] = []
        for raw in draft?.decisionsAndNextSteps ?? [] {
            let clean = cleanBullet(raw, maxWords: 32)
            if !clean.isEmpty && !decisions.contains(clean) { decisions.append(clean) }
            if decisions.count == 4 { break }
        }
        return (Array(bullets.prefix(3)), decisions)
    }

    private static func focusMaterial(
        _ block: DayDigestGeneratedFocusBlock,
        index: Int,
        calendar: Calendar
    ) -> String {
        "- [index \(index)] [\(time(block.start, calendar: calendar))–"
            + "\(time(block.end, calendar: calendar))] "
            + "[\(compactDuration(block.activeDuration)), "
            + "\(Int((block.shareOfRecordedTime * 100).rounded()))%] "
            + "\(block.topic): \(block.summary)"
    }

    private static func renderedBlock(
        _ block: DayDigestGeneratedFocusBlock,
        calendar: Calendar
    ) -> String {
        let citations = block.sourceIDs.map { "[screen:\($0)]" }.joined(separator: " ")
        let suffix = citations.isEmpty ? "" : " \(citations)"
        return "- **\(time(block.start, calendar: calendar))–"
            + "\(time(block.end, calendar: calendar)) · \(block.topic)** — "
            + block.summary + suffix
    }

    private static func compactDuration(_ seconds: TimeInterval) -> String {
        let roundedMinutes = max(0, Int((seconds / 60).rounded()))
        if roundedMinutes >= 60 {
            let hours = roundedMinutes / 60
            let minutes = roundedMinutes % 60
            return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
        }
        return "\(roundedMinutes)m"
    }

    private static func cleanSummary(_ value: String, maxWords: Int) -> String {
        let withoutCitations = value.replacingOccurrences(
            of: #"\[screen:\d+\]"#,
            with: "",
            options: .regularExpression)
        return cleanBullet(withoutCitations, maxWords: maxWords)
    }

    private static func cleanBullet(_ value: String, maxWords: Int) -> String {
        var clean = cleanInline(value, maxCharacters: 420)
        while clean.hasPrefix("-") || clean.hasPrefix("•") {
            clean.removeFirst()
            clean = clean.trimmingCharacters(in: .whitespaces)
        }
        for prefix in ["The user ", "the user ", "User ", "user "] where clean.hasPrefix(prefix) {
            clean.removeFirst(prefix.count)
            if let first = clean.first {
                clean.replaceSubrange(clean.startIndex...clean.startIndex,
                                      with: String(first).uppercased())
            }
            break
        }
        let words = clean.split(whereSeparator: \Character.isWhitespace)
        guard words.count > maxWords else { return clean }
        return words.prefix(maxWords).joined(separator: " ") + "…"
    }

    private static func cleanInline(_ value: String, maxCharacters: Int) -> String {
        PromptContextSanitizer.sanitize(value, maxCharacters: maxCharacters)
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "#*` "))
    }

    private static func time(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
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
    var summaryWarning: String?
}
