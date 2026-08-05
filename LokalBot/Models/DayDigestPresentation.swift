import Foundation

/// A display-oriented projection of the Markdown journal. The journal remains
/// the lossless export format; this model only gives the app a scannable,
/// backwards-compatible hierarchy for both old and newly generated digests.
struct DayDigestPresentation: Equatable {
    struct FocusBlock: Equatable, Identifiable {
        let id: Int
        let markdown: String
        let sourceCount: Int
    }

    struct ActivityEntry: Equatable, Identifiable {
        let id: Int
        let headlineMarkdown: String
        let evidenceMarkdown: [String]
    }

    struct ActivityHourGroup: Equatable, Identifiable {
        let id: String
        let hour: String
        let entries: [ActivityEntry]

        var label: String {
            guard let value = Int(hour) else { return hour }
            return String(format: "%02d:00–%02d:59", value, value)
        }
    }

    struct TimeAllocation: Equatable, Identifiable {
        let id: Int
        let app: String
        let detail: String
        let seconds: TimeInterval
    }

    let atAGlanceMarkdown: String
    let focusBlocks: [FocusBlock]
    let additionalFocusBlocks: [FocusBlock]
    let decisionsMarkdown: String?
    let meetingsMarkdown: String?
    let timeAllocations: [TimeAllocation]
    let activityGroups: [ActivityHourGroup]

    var activityCount: Int {
        activityGroups.reduce(0) { $0 + $1.entries.count }
    }

    var evidenceCount: Int {
        activityGroups.reduce(0) { total, group in
            total + group.entries.reduce(0) { $0 + $1.evidenceMarkdown.count }
        }
    }

    init(markdown: String) {
        let document = Self.levelTwoSections(in: markdown)
        let summarySection = document.first(where: {
            Self.normalized($0.title) == "day summary"
        })
        let summaryBody = summarySection?.body ?? ""
        let summaryParts = Self.levelThreeSections(in: summaryBody)
        let summaryPreamble = Self.preamble(in: summaryBody, before: "### ")

        let legacyWork = document.first(where: {
            ["what i worked on", "work completed and in progress"].contains(
                Self.normalized($0.title))
        })?.body

        let overview = Self.body(
            named: ["at a glance", "overview"], in: summaryParts)
        let focus = Self.body(
            named: ["focus blocks", "work completed and in progress"],
            in: summaryParts) ?? legacyWork
        let decisions = Self.body(
            named: ["decisions and next steps", "decisions, follow-ups, and blockers"],
            in: summaryParts)

        let unknownSummary = summaryParts.filter {
            let title = Self.normalized($0.title)
            return !["at a glance", "overview", "focus blocks",
                     "work completed and in progress", "decisions and next steps",
                     "decisions, follow-ups, and blockers"].contains(title)
        }.map { "### \($0.title)\n\n\($0.body)" }

        atAGlanceMarkdown = Self.joinNonempty(
            [overview, summaryPreamble] + unknownSummary)

        let parsedFocus = Self.focusBlocks(from: focus ?? "")
        focusBlocks = Array(parsedFocus.prefix(8))
        additionalFocusBlocks = Array(parsedFocus.dropFirst(8))
        decisionsMarkdown = Self.meaningful(decisions)

        let meetings = document.first(where: {
            Self.normalized($0.title) == "meetings"
        })?.body
        meetingsMarkdown = Self.meaningful(meetings)

        let timeBody = document.first(where: {
            Self.normalized($0.title) == "time allocation"
        })?.body ?? ""
        timeAllocations = Self.timeAllocations(from: timeBody)

        let activityBody = document.first(where: {
            ["full activity log", "chronological work log"].contains(
                Self.normalized($0.title))
        })?.body ?? ""
        activityGroups = Self.activityGroups(from: activityBody)
    }

    private struct Section {
        var title: String
        var body: String
    }

    private static func levelTwoSections(in markdown: String) -> [Section] {
        sections(in: markdown, prefix: "## ")
    }

    private static func levelThreeSections(in markdown: String) -> [Section] {
        sections(in: markdown, prefix: "### ")
    }

    private static func sections(in markdown: String, prefix: String) -> [Section] {
        var result: [Section] = []
        var title: String?
        var lines: [String] = []

        func finish() {
            guard let title else { return }
            result.append(Section(
                title: title,
                body: lines.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)))
        }

        for line in markdown.components(separatedBy: "\n") {
            if line.hasPrefix(prefix), !line.hasPrefix(prefix + "#") {
                finish()
                title = String(line.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                lines = []
            } else if title != nil {
                lines.append(line)
            }
        }
        finish()
        return result
    }

    private static func body(named names: [String], in sections: [Section]) -> String? {
        sections.first(where: { names.contains(normalized($0.title)) })?.body
    }

    private static func normalized(_ value: String) -> String {
        value
            .replacingOccurrences(of: "‑", with: "-")
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func preamble(in markdown: String, before prefix: String) -> String? {
        let lines = markdown.components(separatedBy: "\n")
        let preamble = lines.prefix { !$0.hasPrefix(prefix) }
            .joined(separator: "\n")
        return meaningful(preamble)
    }

    private static func meaningful(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        let sentinel = clean
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "*", with: "")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines
                .union(CharacterSet(charactersIn: ".")))
            .lowercased()
        let emptyValues = [
            "none", "none recorded", "none found in the evidence",
            "no activity was recorded", "no tracked app time", "no meetings",
        ]
        return emptyValues.contains(sentinel) ? nil : clean
    }

    private static func joinNonempty(_ values: [String?]) -> String {
        values.compactMap(meaningful).joined(separator: "\n\n")
    }

    private static func focusBlocks(from markdown: String) -> [FocusBlock] {
        let clean = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return [] }
        let items = topLevelItems(in: clean)
        let blocks = items.isEmpty ? [clean] : items
        return blocks.enumerated().map { index, block in
            FocusBlock(
                id: index,
                markdown: block,
                sourceCount: occurrences(of: "[screen:", in: block))
        }
    }

    private static func topLevelItems(in markdown: String) -> [String] {
        var items: [String] = []
        var current: [String] = []
        for line in markdown.components(separatedBy: "\n") {
            let isTopLevel = line.first?.isWhitespace == false
                && (line.hasPrefix("- ") || line.hasPrefix("* "))
            if isTopLevel, !current.isEmpty {
                items.append(current.joined(separator: "\n"))
                current = []
            }
            if isTopLevel || !current.isEmpty { current.append(line) }
        }
        if !current.isEmpty { items.append(current.joined(separator: "\n")) }
        return items
    }

    private static func activityGroups(from markdown: String) -> [ActivityHourGroup] {
        let rawItems = topLevelItems(in: markdown)
        var orderedHours: [String] = []
        var grouped: [String: [ActivityEntry]] = [:]

        for (index, item) in rawItems.enumerated() {
            let lines = item.components(separatedBy: "\n")
            guard let first = lines.first else { continue }
            let headline = strippingListMarker(first)
            let evidence = lines.dropFirst().compactMap { line -> String? in
                let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty else { return nil }
                return strippingListMarker(clean)
            }
            let hour = activityHour(from: first) ?? "Other"
            if grouped[hour] == nil { orderedHours.append(hour) }
            grouped[hour, default: []].append(ActivityEntry(
                id: index,
                headlineMarkdown: headline,
                evidenceMarkdown: evidence))
        }

        return orderedHours.map { hour in
            ActivityHourGroup(id: hour, hour: hour, entries: grouped[hour] ?? [])
        }
    }

    private static func activityHour(from line: String) -> String? {
        guard let match = line.range(
            of: #"\*\*([0-2][0-9]):[0-5][0-9]"#,
            options: .regularExpression) else { return nil }
        let token = line[match]
        guard let colon = token.firstIndex(of: ":") else { return nil }
        return String(token[token.index(colon, offsetBy: -2)..<colon])
    }

    private static func strippingListMarker(_ line: String) -> String {
        if line.hasPrefix("- ") || line.hasPrefix("* ") {
            return String(line.dropFirst(2))
        }
        return line
    }

    private static func timeAllocations(from markdown: String) -> [TimeAllocation] {
        var rows: [(String, String)] = []
        for line in markdown.components(separatedBy: "\n") {
            let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard clean.hasPrefix("|"), clean.hasSuffix("|") else { continue }
            let columns = clean.dropFirst().dropLast().split(
                separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard columns.count >= 2 else { continue }
            let first = columns[0]
            let second = columns[1]
            guard normalized(first) != "app",
                  !first.replacingOccurrences(of: "-", with: "").isEmpty else { continue }
            rows.append((unescapeTable(first), unescapeTable(second)))
        }
        return rows.enumerated().map { index, row in
            TimeAllocation(
                id: index,
                app: row.0,
                detail: row.1,
                seconds: durationSeconds(row.1))
        }
    }

    private static func durationSeconds(_ value: String) -> TimeInterval {
        if value.trimmingCharacters(in: .whitespacesAndNewlines) == "<1m" { return 30 }
        var seconds: TimeInterval = 0
        for token in value.lowercased().split(whereSeparator: \Character.isWhitespace) {
            if token.hasSuffix("h"), let hours = Double(token.dropLast()) {
                seconds += hours * 3_600
            } else if token.hasSuffix("m"), let minutes = Double(token.dropLast()) {
                seconds += minutes * 60
            }
        }
        return seconds
    }

    private static func unescapeTable(_ value: String) -> String {
        value.replacingOccurrences(of: "\\|", with: "|")
            .replacingOccurrences(of: "\\*", with: "*")
            .replacingOccurrences(of: "\\_", with: "_")
            .replacingOccurrences(of: "\\[", with: "[")
            .replacingOccurrences(of: "\\]", with: "]")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        return haystack.components(separatedBy: needle).count - 1
    }
}
