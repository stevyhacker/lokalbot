import Foundation

/// Date shortcuts used by Ask's Screen facet. Intervals are half-open to match
/// `ScreenSearchFilter` and are calendar-aware across daylight-saving changes.
enum ScreenSearchDateScope: String, CaseIterable, Identifiable {
    case any = "Any time"
    case today = "Today"
    case yesterday = "Yesterday"
    case sevenDays = "7 days"

    var id: String { rawValue }

    func interval(now: Date = Date(), calendar: Calendar = .current) -> DateInterval? {
        switch self {
        case .any:
            return nil
        case .today:
            return ActivityStore.dayInterval(containing: now, calendar: calendar)
        case .yesterday:
            let day = calendar.date(byAdding: .day, value: -1, to: now)
                ?? now.addingTimeInterval(-86_400)
            return ActivityStore.dayInterval(containing: day, calendar: calendar)
        case .sevenDays:
            let today = ActivityStore.dayInterval(containing: now, calendar: calendar)
            let start = calendar.date(byAdding: .day, value: -6, to: today.start)
                ?? today.start.addingTimeInterval(-6 * 86_400)
            return DateInterval(start: start, end: today.end)
        }
    }
}

/// A screen result explicitly attached to the next Ask question. Keeping the
/// OCR excerpt with the stable snapshot id avoids a second text query and lets
/// the local text model reason over the selected pixels' captured text.
struct ScreenAskContext: Equatable, Identifiable {
    let snapshotID: Int64
    let timestamp: Date
    let app: String
    let windowTitle: String
    let snippet: String

    var id: Int64 { snapshotID }

    init(hit: ActivityStore.OCRHit) {
        snapshotID = hit.snapshotID
        timestamp = hit.ts
        app = hit.app
        windowTitle = hit.windowTitle
        snippet = hit.snippet
    }

    init(screenshot: ActivityStore.Screenshot, ocrText: String) {
        snapshotID = screenshot.id
        timestamp = screenshot.ts
        app = screenshot.app
        windowTitle = screenshot.windowTitle
        snippet = ocrText
    }

    /// Adds primary-evidence context for the model while the UI can still show
    /// only the user's concise question in the transcript.
    static func prompt(question: String, contexts: [ScreenAskContext]) -> String {
        guard !contexts.isEmpty else { return question }
        let sources = contexts.map { context in
            let window = context.windowTitle.isEmpty ? "" : " — \(clean(context.windowTitle))"
            return "- [screen:\(context.snapshotID)] \(context.app)\(window), "
                + "\(context.timestamp.formatted(date: .abbreviated, time: .shortened))\n"
                + "  Captured text: \(clean(context.snippet))"
        }.joined(separator: "\n")
        return """
        Screen context explicitly selected by the user. Treat it as primary evidence and use the exact [screen:ID] marker when citing it:
        \(sources)

        Question: \(question)
        """
    }

    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "«", with: "")
            .replacingOccurrences(of: "»", with: "")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
