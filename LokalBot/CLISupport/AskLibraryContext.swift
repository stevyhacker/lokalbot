import Foundation

/// Pure retrieval, citation, and prompt construction for `ask_library`.
enum AskLibraryContext {
    static let maxSnippets = 12
    static let maxTitleSummaryMatches = 4
    static let maxSummaryUTF8Bytes = 6 * 1_024
    static let maxSnippetLineUTF8Bytes = 1_024
    static let maxContextUTF8Bytes = 32 * 1_024

    struct Citation: Encodable, Equatable {
        var meeting_id: String
        var title: String
        var date: String
    }

    struct ContextBundle: Equatable {
        var contextText: String
        var citations: [Citation]
    }

    static func searchTerms(from question: String) -> [String] {
        let stopwords: Set<String> = [
            "what", "when", "where", "which", "whom", "about", "does", "that",
            "this", "with", "have", "from", "were", "they", "their", "them",
            "will", "would", "should", "could", "meeting", "meetings",
            "please", "tell",
        ]
        var seen: Set<String> = []
        return question.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter {
                $0.count >= 4 && !stopwords.contains($0) && seen.insert($0).inserted
            }
    }

    static func build(question: String, meetings: [Meeting]) -> ContextBundle {
        let byShortID = Dictionary(
            meetings.map { (SessionLookup.shortID($0.id), $0) },
            uniquingKeysWith: { first, _ in first })
        var context = ContextWriter()
        var citedShortIDs: [String] = []

        let lowered = question.lowercased()
        let titleMatches = meetings.compactMap { meeting -> (meeting: Meeting, title: String)? in
            let title = meeting.title.trimmingCharacters(in: .whitespaces)
            guard title.count >= 4,
                  lowered.contains(title.lowercased()) else { return nil }
            return (meeting, title)
        }
        .sorted { lhs, rhs in
            if lhs.title.count != rhs.title.count { return lhs.title.count > rhs.title.count }
            if lhs.meeting.startedAt != rhs.meeting.startedAt {
                return lhs.meeting.startedAt > rhs.meeting.startedAt
            }
            return lhs.meeting.id.uuidString < rhs.meeting.id.uuidString
        }

        var appendedSummaries = 0
        for match in titleMatches {
            guard appendedSummaries < maxTitleSummaryMatches,
                  !context.isFull else { break }
            guard let summary = SessionLookup.summaryMarkdown(for: match.meeting) else { continue }
            let boundedSummary = truncatedUTF8(
                summary,
                maxBytes: maxSummaryUTF8Bytes,
                marker: "\n[… summary truncated …]")
            let section = "## \(match.meeting.title) — \(dayString(match.meeting.startedAt)) — full summary\n\(boundedSummary)"
            if context.appendSection(section) {
                appendedSummaries += 1
                citedShortIDs.append(SessionLookup.shortID(match.meeting.id))
            }
        }

        var snippetCount = 0
        var hasSnippetSection = false
        var seenSnippets: Set<String> = []
        search: for term in searchTerms(from: question) {
            guard snippetCount < maxSnippets, !context.isFull else { break }
            let hits = (try? LibrarySearch.hits(
                query: term,
                limit: maxSnippets,
                meetings: meetings)) ?? []
            for hit in hits {
                guard snippetCount < maxSnippets, !context.isFull else { break search }
                guard seenSnippets.insert("\(hit.meeting_id)|\(hit.snippet)").inserted else {
                    continue
                }
                let stamp = hit.timestamp.map { " @\($0)" } ?? ""
                let line = truncatedUTF8(
                    "- [\(hit.match_kind)\(stamp)] \(hit.meeting_title): \(hit.snippet)",
                    maxBytes: maxSnippetLineUTF8Bytes,
                    marker: "…")
                let prefix: String
                if hasSnippetSection {
                    prefix = "\n"
                } else {
                    prefix = context.text.isEmpty ? "## Snippets\n" : "\n\n## Snippets\n"
                }
                guard context.appendFragment(prefix + line) else { break search }
                hasSnippetSection = true
                snippetCount += 1
                citedShortIDs.append(hit.meeting_id)
            }
        }

        var seenIDs: Set<String> = []
        let citations = citedShortIDs
            .filter { seenIDs.insert($0).inserted }
            .compactMap { byShortID[$0] }
            .sorted { $0.startedAt > $1.startedAt }
            .map {
                Citation(
                    meeting_id: SessionLookup.shortID($0.id),
                    title: $0.title,
                    date: dayString($0.startedAt))
            }

        return ContextBundle(
            contextText: context.text,
            citations: citations)
    }

    static func messages(question: String, contextText: String) -> [[String: String]] {
        [
            [
                "role": "system",
                "content": "You are LokalBot's meeting-library assistant. Answer the user's question using ONLY the meeting context provided. Cite the meetings you used by title and date. If the context does not contain the answer, reply exactly: I couldn't find that in your meetings.",
            ],
            [
                "role": "user",
                "content": "Meeting context:\n\n\(contextText)\n\nQuestion: \(question)",
            ],
        ]
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func dayString(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    private struct ContextWriter {
        private(set) var text = ""
        private var usedBytes = 0

        var isFull: Bool { usedBytes >= maxContextUTF8Bytes }

        mutating func appendSection(_ section: String) -> Bool {
            appendFragment((text.isEmpty ? "" : "\n\n") + section)
        }

        mutating func appendFragment(_ fragment: String) -> Bool {
            let available = maxContextUTF8Bytes - usedBytes
            guard available > 0, !fragment.isEmpty else { return false }
            let bounded = truncatedUTF8(
                fragment,
                maxBytes: available,
                marker: "\n[… context budget reached …]")
            guard !bounded.isEmpty else { return false }
            text += bounded
            usedBytes += bounded.utf8.count
            return true
        }
    }

    private static func truncatedUTF8(
        _ value: String,
        maxBytes: Int,
        marker: String
    ) -> String {
        guard maxBytes > 0 else { return "" }
        guard value.utf8.count > maxBytes else { return value }
        let markerBytes = marker.utf8.count
        let canAppendMarker = markerBytes <= maxBytes
        let prefixBudget = canAppendMarker ? maxBytes - markerBytes : maxBytes
        var prefixData = Data(value.utf8.prefix(prefixBudget))
        while !prefixData.isEmpty,
              String(data: prefixData, encoding: .utf8) == nil {
            prefixData.removeLast()
        }
        let prefix = String(data: prefixData, encoding: .utf8) ?? ""
        return canAppendMarker ? prefix + marker : prefix
    }
}
