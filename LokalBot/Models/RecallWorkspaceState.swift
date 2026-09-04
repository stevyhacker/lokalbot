import Foundation

/// Shared, session-lived navigation state. Opening evidence does not discard
/// the selected filters, attachments, result or unfinished question.
struct RecallWorkspaceState {
    var meetingIDs: Set<UUID>?
    var screenIDs: Set<Int64>?
    var selectedResult = 0
    var facet: AskFacet = .all
    var meaning = false
    var screenDate: ScreenSearchDateScope = .any
    var screenApp: String?
    var sources = AskSourceScope.defaults
    var pins: [ScreenAskContext] = []
}

struct ScreenRecallGroup: Identifiable {
    let id: String
    let matches: [ActivityStore.OCRHit]
    var primary: ActivityStore.OCRHit { matches[0] }
}

extension RecallSearch {
    struct Result {
        var meetings: [MeetingRecallGroup] = []
        var screens: [ScreenRecallGroup] = []
    }

    /// Rank first, then group nearby hits from the same source window. Every
    /// matching capture stays available inside its group and bounded Ask scope.
    static func screenGroups(_ hits: [ActivityStore.OCRHit], limit: Int = 40) -> [ScreenRecallGroup] {
        var groups: [[ActivityStore.OCRHit]] = []
        for hit in hits {
            if let index = groups.firstIndex(where: { group in
                group.contains { other in
                    other.app == hit.app && other.windowTitle == hit.windowTitle
                        && Calendar.current.isDate(other.ts, inSameDayAs: hit.ts)
                        && abs(other.ts.timeIntervalSince(hit.ts)) <= 300
                }
            }) { groups[index].append(hit) } else { groups.append([hit]) }
        }
        return groups.prefix(limit).map { ScreenRecallGroup(id: "screen-\($0[0].snapshotID)", matches: $0) }
    }

    @MainActor
    static func search(_ query: String, state: RecallWorkspaceState, day: Date?, app: AppState) async -> Result {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return Result() }
        var result = Result()
        var meetingIDs = state.meetingIDs
        if let day {
            let dayIDs = Set(app.meetings.filter { Calendar.current.isDate($0.startedAt, inSameDayAs: day) }.map(\.id))
            meetingIDs = meetingIDs.map { $0.intersection(dayIDs) } ?? dayIDs
        }
        if state.facet != .screen {
            var hits = app.searchIndex.search(query, kind: state.facet.kind, limit: 2_000, meetingIDs: meetingIDs)
            if state.meaning, state.facet == .all, app.embeddingIndex.hasEmbeddings {
                let semantic = await app.embeddingIndex.search(query, limit: 200, meetingIDs: meetingIDs)
                guard !Task.isCancelled else { return Result() }
                hits += semantic.map { SearchIndex.Hit(meetingID: $0.meetingID, kind: .segment, start: $0.start, snippet: $0.text, speaker: "Meaning match") }
            }
            result.meetings = groups(hits)
        }
        if state.facet == .all || state.facet == .screen {
            let interval = day.flatMap { Calendar.current.dateInterval(of: .day, for: $0) } ?? state.screenDate.interval()
            var filter = ScreenSearchFilter(interval: interval, app: state.screenApp)
            filter.snapshotIDs = state.screenIDs
            var hits = app.activityStore.searchOCR(query, limit: 2_000, filter: filter, groupResults: false)
            if hits.isEmpty { hits = app.activityStore.searchOCR(query, limit: 2_000, matchAll: false, dropStopWords: true, filter: filter, groupResults: false) }
            let found = Set(hits.map(\.snapshotID))
            let saved = app.activityStore.savedMoments(limit: 2_000).filter { moment in
                !found.contains(moment.snapshotID)
                    && (filter.snapshotIDs?.contains(moment.snapshotID) ?? true)
                    && (filter.interval.map { moment.ts >= $0.start && moment.ts < $0.end } ?? true)
                    && (filter.app.map { $0.caseInsensitiveCompare(moment.app) == .orderedSame } ?? true)
                    && [moment.note, moment.windowTitle].contains { $0.localizedCaseInsensitiveContains(query) }
            }
            hits += saved.map { ActivityStore.OCRHit(snapshotID: $0.snapshotID, ts: $0.ts, app: $0.app, windowTitle: $0.windowTitle, snippet: $0.note) }
            if state.meaning, app.embeddingIndex.hasScreenEmbeddings {
                let semantic = await app.embeddingIndex.searchScreen(query, filter: filter, limit: 200)
                guard !Task.isCancelled else { return Result() }
                let existing = Set(hits.map(\.snapshotID))
                hits += semantic.filter { !existing.contains($0.snapshotID) }.compactMap { hit in
                    guard let shot = app.activityStore.screenshot(id: hit.snapshotID) else { return nil }
                    return ActivityStore.OCRHit(snapshotID: hit.snapshotID, ts: shot.ts, app: shot.app, windowTitle: shot.windowTitle, snippet: hit.text)
                }
            }
            result.screens = screenGroups(hits)
        }
        return result
    }
}
