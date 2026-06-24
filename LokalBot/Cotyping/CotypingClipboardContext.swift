import AppKit
import Foundation

/// Sanitized clipboard context folded into the cotyping prompt so the model can
/// "see" what was just copied — a trimmed port of Cotabby's clipboard context
/// (`ClipboardContextProvider` + `SuggestionRequestFactory` clipping). The
/// sanitization, bounding, and an "already-in-the-field" guard are pure here;
/// reading the pasteboard is a thin runtime wrapper (`CotypingClipboardProvider`).
///
/// Privacy: off by default; the clipboard is read only at generation time and
/// never cached, persisted, or logged.
enum CotypingClipboardContext {
    /// Hard cap on the snippet included in the prompt (mirrors Cotabby's 1_200).
    static let maxSnippetCharacters = 1_200

    /// Sanitizes raw clipboard text: collapses internal whitespace runs (newlines,
    /// tabs, repeats) to a single space, trims the ends, and caps the length. Nil
    /// for empty / whitespace-only input.
    static func sanitize(_ raw: String?, maxCharacters: Int = maxSnippetCharacters) -> String? {
        guard let raw else { return nil }
        let collapsed = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let trimmed = collapsed.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count <= maxCharacters ? trimmed : String(trimmed.prefix(maxCharacters))
    }

    /// Whether a clipboard snippet is worth including: false when it is empty, or
    /// when it is already present in the text the user is typing (no point
    /// re-injecting what is already in the field — e.g. right after pasting it).
    static func shouldInclude(snippet: String?, precedingText: String) -> Bool {
        guard let snippet, !snippet.isEmpty else { return false }
        return !precedingText.contains(snippet)
    }

    /// Convenience: sanitize + guard → the snippet to include, or nil.
    static func resolve(rawClipboard: String?, precedingText: String,
                        maxCharacters: Int = maxSnippetCharacters) -> String? {
        guard let snippet = sanitize(rawClipboard, maxCharacters: maxCharacters),
              shouldInclude(snippet: snippet, precedingText: precedingText) else { return nil }
        return snippet
    }
}

/// Reads the system pasteboard. `@MainActor`; the snippet is read fresh at
/// generation time and never cached or persisted (clipboard contents are
/// sensitive and change outside our control). Injectable for tests.
@MainActor
final class CotypingClipboardProvider {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    /// The current plain-text clipboard contents, or nil.
    var currentText: String? { pasteboard.string(forType: .string) }
}
