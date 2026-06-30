import AppKit
import Foundation

/// Sanitized clipboard context folded into the cotyping prompt so the model can
/// "see" what was just copied — a trimmed port of Cotabby's clipboard context
/// (`ClipboardRelevanceFilter` + request-factory clipping). The sanitization,
/// bounding, relevance checks, and an "already-in-the-field" guard are pure
/// here; reading the pasteboard is a thin runtime wrapper
/// (`CotypingClipboardProvider`).
///
/// Privacy: off by default; snippets may be memoized in memory for one focused
/// field/pasteboard state to keep the prompt prefix stable, but are never
/// persisted or logged.
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

    static func significantTokens(from text: String, minimumLength: Int = 3) -> Set<String> {
        Set(
            text.lowercased()
                .split { character in
                    !character.isLetter && !character.isNumber
                }
                .map(String.init)
                .filter { $0.count >= minimumLength }
        )
    }
}

/// CoTabby-style gate for clipboard context. The first pasteboard observation is
/// treated as an unknown-age baseline, not a fresh copy. Only later copies made
/// during this app session can enter the prompt, and then only while fresh and
/// related to the typed prefix.
final class CotypingClipboardRelevanceFilter {
    static let staleThresholdSeconds: TimeInterval = 300

    private var lastKnownChangeCount: Int?
    private var lastChangeDate: Date?
    private let dateProvider: () -> Date

    init(dateProvider: @escaping () -> Date = { Date() }) {
        self.dateProvider = dateProvider
    }

    func filter(
        rawClipboard: String?,
        pasteboardChangeCount: Int,
        precedingText: String
    ) -> String? {
        guard let rawClipboard else { return nil }

        guard let baselineChangeCount = lastKnownChangeCount else {
            lastKnownChangeCount = pasteboardChangeCount
            return nil
        }

        if pasteboardChangeCount != baselineChangeCount {
            lastKnownChangeCount = pasteboardChangeCount
            lastChangeDate = dateProvider()
        }

        guard let lastChangeDate,
              dateProvider().timeIntervalSince(lastChangeDate) < Self.staleThresholdSeconds else {
            return nil
        }

        let clipboardTokens = CotypingClipboardContext.significantTokens(from: rawClipboard)
        let prefixTokens = CotypingClipboardContext.significantTokens(from: precedingText)
        guard !clipboardTokens.isEmpty,
              !clipboardTokens.isDisjoint(with: prefixTokens) else {
            return nil
        }

        return rawClipboard
    }

    func reset() {
        lastKnownChangeCount = nil
        lastChangeDate = nil
    }
}

/// One pinned, non-empty clipboard-context verdict for a focused field and a
/// pasteboard state. Nil verdicts are intentionally not represented: they add
/// nothing to the prompt and should re-evaluate as the user types more context.
nonisolated struct CotypingClipboardPrefaceMemo: Equatable, Sendable {
    let identityKey: String
    let changeCount: Int
    let value: String

    func valueIfReusable(identityKey: String, changeCount: Int) -> String? {
        guard self.identityKey == identityKey,
              self.changeCount == changeCount else { return nil }
        return value
    }
}

/// Reads the system pasteboard. `@MainActor`; the snippet is read fresh at
/// generation time and never persisted (clipboard contents are sensitive and
/// change outside our control). Injectable for tests.
@MainActor
final class CotypingClipboardProvider {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    /// The current plain-text clipboard contents, or nil.
    var currentText: String? { pasteboard.string(forType: .string) }

    var changeCount: Int { pasteboard.changeCount }
}
