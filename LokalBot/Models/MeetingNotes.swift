import Foundation

/// The user's own quick notes taken during a meeting — a plain `notes.md`
/// beside the audio in the meeting folder. Written live by the recording
/// panel and folded into the summary + outcomes prompts as high-signal
/// context (the user typed it; the model should trust it over its own
/// paraphrase of the transcript).
enum MeetingNotes {

    static let fileName = "notes.md"

    /// The saved notes, or nil when there are none (missing file or blank).
    /// Read failures are surfaced so callers never mistake inaccessible notes
    /// for an intentionally empty document.
    static func load(from folder: URL) throws -> String? {
        let url = folder.appendingPathComponent(fileName)
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch where FileSystemSupport.isMissing(error) {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Atomically persist notes. Clearing the text removes the file so empty
    /// notes never haunt the summary prompt.
    static func write(_ text: String, to folder: URL) throws {
        let url = folder.appendingPathComponent(fileName)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try FileSystemSupport.removeIfPresent(url)
            return
        }
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    /// Generation-context block for the summary/outcomes prompts; empty when
    /// the meeting has no notes.
    static func promptContext(in folder: URL) throws -> [String] {
        guard let notes = try load(from: folder) else { return [] }
        return ["Notes the user typed during this meeting — high-signal, incorporate and prioritize them:\n\(notes)"]
    }
}
