import Foundation

/// Pure retrieval, citation, and prompt construction for `ask_library`.
enum AskLibraryContext {
    static let maxSnippets = 12

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
        var sections: [String] = []
        var citedShortIDs: [String] = []

        let lowered = question.lowercased()
        for meeting in meetings {
            let title = meeting.title.trimmingCharacters(in: .whitespaces)
            guard title.count >= 4,
                  lowered.contains(title.lowercased()),
                  let summary = SessionLookup.summaryMarkdown(for: meeting) else {
                continue
            }
            sections.append(
                "## \(meeting.title) — \(dayString(meeting.startedAt)) — full summary\n\(summary)")
            citedShortIDs.append(SessionLookup.shortID(meeting.id))
        }

        var snippetLines: [String] = []
        var seenSnippets: Set<String> = []
        for term in searchTerms(from: question) {
            guard snippetLines.count < maxSnippets else { break }
            let hits = (try? LibrarySearch.hits(
                query: term,
                limit: maxSnippets,
                meetings: meetings)) ?? []
            for hit in hits {
                guard snippetLines.count < maxSnippets else { break }
                guard seenSnippets.insert("\(hit.meeting_id)|\(hit.snippet)").inserted else {
                    continue
                }
                let stamp = hit.timestamp.map { " @\($0)" } ?? ""
                snippetLines.append(
                    "- [\(hit.match_kind)\(stamp)] \(hit.meeting_title): \(hit.snippet)")
                citedShortIDs.append(hit.meeting_id)
            }
        }
        if !snippetLines.isEmpty {
            sections.append("## Snippets\n" + snippetLines.joined(separator: "\n"))
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
            contextText: sections.joined(separator: "\n\n"),
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
}
