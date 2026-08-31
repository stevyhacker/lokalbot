import Foundation

/// A background-safe snapshot of the small text artifacts rendered by meeting
/// views. Missing artifacts are normal while processing is still in flight;
/// unreadable or corrupt artifacts are reported explicitly.
struct MeetingArtifactSnapshot: Sendable {
    struct Issue: Equatable, Sendable {
        let artifact: String
        let detail: String

        var message: String { "Could not load \(artifact): \(detail)" }
    }

    let summary: String?
    let notes: String?
    let transcript: Transcript?
    let issues: [Issue]
}

enum MeetingArtifactLoader {
    static func loadWorkspace(from folder: URL) -> MeetingArtifactSnapshot {
        var issues: [MeetingArtifactSnapshot.Issue] = []

        let summary = capture("summary", issues: &issues) {
            try loadSummary(from: folder)
        }
        let notes = capture("notes", issues: &issues) {
            try MeetingNotes.load(from: folder)
        }
        let transcript = capture("transcript", issues: &issues) {
            try loadTranscript(from: folder)
        }

        return MeetingArtifactSnapshot(
            summary: summary,
            notes: notes,
            transcript: transcript,
            issues: issues)
    }

    static func loadSummary(from folder: URL) throws -> String? {
        try loadTextIfPresent(at: folder.appendingPathComponent("summary.md"))
    }

    private static func loadTranscript(from folder: URL) throws -> Transcript? {
        let url = folder.appendingPathComponent("transcript.json")
        do {
            return try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: url))
        } catch where FileSystemSupport.isMissing(error) {
            return nil
        }
    }

    private static func loadTextIfPresent(at url: URL) throws -> String? {
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch where FileSystemSupport.isMissing(error) {
            return nil
        }
    }

    private static func capture<Value>(_ artifact: String,
                                       issues: inout [MeetingArtifactSnapshot.Issue],
                                       operation: () throws -> Value?) -> Value? {
        do {
            return try operation()
        } catch {
            issues.append(.init(artifact: artifact, detail: error.localizedDescription))
            return nil
        }
    }
}
