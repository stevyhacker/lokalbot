import Foundation

/// Plants a self-contained LokalBotV2 storage root on disk for one UI test run.
/// Mirrors `StorageManager`'s on-disk layout
/// (`meetings/YYYY/MM/dd-slug/{meta.json, transcript.json, transcript.md, summary.md}`)
/// without `@testable`-importing the app — the UI test bundle runs out-of-process,
/// so it stays decoupled and only the file shape matters.
///
/// Every meeting is deterministic: stable UUIDs, stable text, dates anchored
/// to `now` so the grouping headers always read "TODAY" / "YESTERDAY".
enum SyntheticFixture {

    /// Static handle on one planted fixture: the tmp `root` to point
    /// `LOKALBOTV2_STORAGE_ROOT` at, plus the three meetings the tests assert on.
    struct Library {
        let root: URL
        let designReview: Meeting
        let standup: Meeting
        let planning: Meeting

        /// The full meeting set, in display order (newest first).
        var meetings: [Meeting] { [designReview, standup, planning] }

        /// On-disk folder for a planted meeting, mirroring
        /// `Meeting.folderURL(in:)` (`root/relativePath`). Lets a test assert
        /// that a delete actually reached the filesystem, not just the list.
        func folder(for meeting: Meeting) -> URL {
            root.appendingPathComponent(meeting.relativePath, isDirectory: true)
        }

        /// Remove every byte we planted — call from `tearDown` so a leftover
        /// fixture never pollutes the next run's storage root.
        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// Lightweight meeting descriptor — the UI tests assert against these
    /// fields, so all the strings that show up on screen live in one place.
    struct Meeting {
        let id: UUID
        let title: String
        let appName: String
        let startedAt: Date
        let endedAt: Date
        let relativePath: String
        let hasSystemTrack: Bool
        let transcript: [Segment]
        let summaryMarkdown: String

        struct Segment {
            let start: TimeInterval
            let end: TimeInterval
            let speaker: String   // "me" | "them"
            let text: String
        }
    }

    /// Build a fresh tmp library and write every fixture file to disk.
    /// Caller passes the resulting `root` to the app as `LOKALBOTV2_STORAGE_ROOT`.
    static func plant() throws -> Library {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LokalBotV2UITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("meetings"), withIntermediateDirectories: true)

        let now = Date()
        let yesterday = now.addingTimeInterval(-24 * 3_600)

        let designReview = Meeting(
            id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            title: "Design review meeting",
            appName: "Zoom",
            startedAt: now.addingTimeInterval(-3_600),          // an hour ago
            endedAt: now.addingTimeInterval(-3_600 + 25 * 60),  // 25-min meeting
            relativePath: relativePath(for: now.addingTimeInterval(-3_600),
                                       slug: "design-review-meeting"),
            hasSystemTrack: true,
            transcript: [
                .init(start: 0, end: 12, speaker: "me",
                      text: "Let's decide on the caching layer. I propose Redis because of pub-sub support."),
                .init(start: 12, end: 24, speaker: "them",
                      text: "Agreed on Redis. One open question: do we need cluster mode from day one?"),
                .init(start: 24, end: 35, speaker: "me",
                      text: "I'll draft the eviction policy document by Thursday."),
                .init(start: 35, end: 48, speaker: "them",
                      text: "Please benchmark failover latency before we commit."),
            ],
            summaryMarkdown: """
            ## TL;DR
            The team picked Redis for the caching layer and deferred cluster mode pending a failover benchmark.

            ## Decisions
            - Adopt Redis for caching (pub-sub support won the comparison).

            ## Action items
            - [ ] Draft the eviction policy document by Thursday (Me).
            - [ ] Benchmark failover latency before committing to cluster mode (Them).
            """)

        let standup = Meeting(
            id: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
            title: "Engineering standup",
            appName: "Slack",
            startedAt: now.addingTimeInterval(-7_200),          // 2h ago
            endedAt: now.addingTimeInterval(-7_200 + 15 * 60),  // 15-min standup
            relativePath: relativePath(for: now.addingTimeInterval(-7_200),
                                       slug: "engineering-standup"),
            hasSystemTrack: false,
            transcript: [
                .init(start: 0, end: 8, speaker: "me",
                      text: "Quick standup. I'm picking up the Postgres migration today."),
                .init(start: 8, end: 18, speaker: "me",
                      text: "Blocker on the index rebuild — needs review from the data team."),
            ],
            summaryMarkdown: """
            ## TL;DR
            Postgres migration kick-off; index rebuild blocked on data-team review.

            ## Action items
            - [ ] Unblock the index rebuild with the data team (Me).
            """)

        let planning = Meeting(
            id: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
            title: "Q3 roadmap planning",
            appName: "Manual",
            startedAt: yesterday,
            endedAt: yesterday.addingTimeInterval(35 * 60),     // 35-min planning
            relativePath: relativePath(for: yesterday, slug: "q3-roadmap-planning"),
            hasSystemTrack: false,
            transcript: [
                .init(start: 0, end: 20, speaker: "me",
                      text: "We need to lock down the Q3 roadmap. Onboarding is the top priority for new accounts."),
                .init(start: 20, end: 40, speaker: "me",
                      text: "Second priority is reliability work — the alerting backlog has grown three quarters in a row."),
            ],
            summaryMarkdown: """
            ## TL;DR
            Q3 priorities are onboarding (top) and reliability (alerting backlog).

            ## Decisions
            - Onboarding ranks above reliability for Q3.
            """)

        for meeting in [designReview, standup, planning] {
            try write(meeting, under: root)
        }
        return Library(root: root, designReview: designReview,
                       standup: standup, planning: planning)
    }

    // MARK: - Helpers

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func relativePath(for date: Date, slug: String) -> String {
        let cal = Calendar.current
        let year = cal.component(.year, from: date)
        let month = String(format: "%02d", cal.component(.month, from: date))
        let day = String(format: "%02d", cal.component(.day, from: date))
        return "meetings/\(year)/\(month)/\(day)-\(slug)"
    }

    private static func write(_ meeting: Meeting, under root: URL) throws {
        let folder = root.appendingPathComponent(meeting.relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // meta.json — must round-trip through StorageManager.loadMeetings()
        let meta = """
        {
          "appName" : "\(meeting.appName)",
          "endedAt" : "\(isoFormatter.string(from: meeting.endedAt))",
          "hasSystemTrack" : \(meeting.hasSystemTrack ? "true" : "false"),
          "id" : "\(meeting.id.uuidString)",
          "relativePath" : "\(meeting.relativePath)",
          "startedAt" : "\(isoFormatter.string(from: meeting.startedAt))",
          "title" : "\(meeting.title)"
        }
        """
        try meta.write(to: folder.appendingPathComponent("meta.json"),
                       atomically: true, encoding: .utf8)

        // transcript.json — consumed by SearchIndex.reindex and MeetingDetailView.
        let segments = meeting.transcript.map { segment -> String in
            """
              {
                "start" : \(segment.start),
                "end" : \(segment.end),
                "speaker" : "\(segment.speaker)",
                "text" : \(jsonString(segment.text))
              }
            """
        }.joined(separator: ",\n")
        let transcriptJSON = """
        {
          "engine" : "synthetic-fixture",
          "segments" : [
        \(segments)
          ]
        }
        """
        try transcriptJSON.write(to: folder.appendingPathComponent("transcript.json"),
                                 atomically: true, encoding: .utf8)

        // Human-readable transcript.md (mirrors ProcessingPipeline.write).
        let markdown = meeting.transcript.map { segment in
            "**[\(stamp(segment.start))] \(segment.speaker.capitalized):** \(segment.text)"
        }.joined(separator: "\n\n")
        try markdown.write(to: folder.appendingPathComponent("transcript.md"),
                           atomically: true, encoding: .utf8)

        // summary.md — rendered by MarkdownText in the Summary tab.
        try meeting.summaryMarkdown.write(to: folder.appendingPathComponent("summary.md"),
                                          atomically: true, encoding: .utf8)
    }

    /// Minimal JSON-string escaper for the few control characters we ever emit.
    private static func jsonString(_ raw: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(raw.count + 2)
        escaped.append("\"")
        for scalar in raw.unicodeScalars {
            switch scalar {
            case "\\": escaped.append("\\\\")
            case "\"": escaped.append("\\\"")
            case "\n": escaped.append("\\n")
            case "\r": escaped.append("\\r")
            case "\t": escaped.append("\\t")
            default:
                if scalar.value < 0x20 {
                    escaped.append(String(format: "\\u%04x", scalar.value))
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }
        escaped.append("\"")
        return escaped
    }

    private static func stamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d:%02d", total / 3_600, (total % 3_600) / 60, total % 60)
    }
}
