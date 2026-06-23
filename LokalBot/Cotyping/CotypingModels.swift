import CoreGraphics
import Foundation

/// Cotyping — LokalBot's third major feature: on-device, inline AI autocomplete
/// in (almost) any macOS text field, reusing the same local LLM backend that
/// powers summarization. Modeled on Cotabby's suggestion pipeline but driven by
/// LokalBot's HTTP `llama-server` (`/v1/completions`) instead of in-process
/// llama.cpp.
///
/// This file holds the value types shared across the cotyping subsystem. They
/// are deliberately `Sendable` value types so they can cross the async /
/// main-actor boundaries the pipeline runs over (focus poll → debounce →
/// generation → overlay → acceptance) without aliasing live AX handles.

/// Whether the currently focused element can host a suggestion.
enum CotypingCapability: Equatable, Sendable {
    /// An editable text field with a collapsed caret — suggestions allowed.
    case supported
    /// Editable, but a suggestion is intentionally withheld (secure field, or a
    /// non-empty selection). The string is a short human-readable reason.
    case blocked(String)
    /// Not an editable text field we can drive (button, web link, image, …).
    case unsupported(String)

    var isSupported: Bool { if case .supported = self { true } else { false } }
}

/// A value-type snapshot of the focused editable field. Produced by
/// `CotypingAXHelper`/`CotypingFocusTracker` from a synchronous Accessibility
/// read and then carried, unaliased, through the rest of the pipeline.
struct CotypingField: Equatable, Sendable {
    var appName: String
    var bundleID: String?
    var processID: pid_t
    var role: String
    /// Bounded text immediately before the caret (newest text at the end).
    var precedingText: String
    /// Bounded text immediately after the caret (used by the trailing-duplication filter).
    var trailingText: String
    /// 0 means a collapsed caret; >0 means an active selection (suppresses suggestions).
    var selectionLength: Int
    /// Caret rectangle in global Cocoa coordinates (bottom-left origin, already
    /// Y-flipped against the primary display in `CotypingAXHelper`).
    var caretRect: CGRect
    /// True for password / secure-entry fields — never read or suggested into.
    var isSecure: Bool
    /// `true` when the caret rect came from an exact AX range query; `false`
    /// when it was estimated from the field frame (lower placement confidence).
    var caretIsExact: Bool
    /// The focused window's title (email subject, doc name, chat channel, page
    /// title) when app-context is enabled — the strongest topic cue we get.
    var windowTitle: String? = nil
    /// The field's placeholder / label (e.g. "To:", "Search", "Message #general").
    var fieldPlaceholder: String? = nil

    /// Content-only fingerprint used to detect "did the field actually change"
    /// across keystrokes and to drop stale async generations. Excludes the AX
    /// element identity on purpose: web engines recycle element handles.
    var contentSignature: String {
        [String(selectionLength), precedingText, trailingText, isSecure ? "secure" : "plain"]
            .joined(separator: "\u{1f}")
    }
}

/// The focus tracker's published result: which app is focused, whether we can
/// suggest there, and (when supported) the field snapshot.
struct CotypingFocus: Equatable, Sendable {
    var appName: String
    var bundleID: String?
    var capability: CotypingCapability
    var field: CotypingField?

    static let none = CotypingFocus(
        appName: "", bundleID: nil,
        capability: .unsupported("No focused text field."), field: nil)
}

/// Sampling + windowing knobs for one generation. Defaults mirror Cotabby's
/// shipped `SuggestionConfiguration.standard` (low temperature for stable inline
/// completions); the fixed seed keeps identical context reproducible.
struct CotypingConfiguration: Sendable, Equatable {
    var maxPrefixCharacters: Int
    var maxPrefixWords: Int
    var maxResponseTokens: Int
    var temperature: Double
    var topP: Double
    var topK: Int
    var minP: Double
    var repeatPenalty: Double
    var seed: Int

    static let standard = CotypingConfiguration(
        maxPrefixCharacters: 2500,
        maxPrefixWords: 150,
        maxResponseTokens: 24,
        temperature: 0.1,
        topP: 0.7,
        topK: 20,
        minP: 0.08,
        repeatPenalty: 1.05,
        // 0x00C0FFEE — Cotabby's "coffee" sampler seed; stable so the same
        // context yields the same ghost text.
        seed: 0x00C0_FFEE)
}

/// One generation request handed to `CotypingCompleting`. Carries everything the
/// engine needs to call the model AND everything `CotypingTextNormalizer` needs
/// to clean the result, so the normalizer stays a pure function of the request.
struct CotypingRequest: Sendable, Equatable {
    /// The full rendered prompt (optional conditioning preface + caret prefix).
    let prompt: String
    /// The windowed caret prefix alone (used to strip prefix echoes from output).
    let prefixText: String
    /// Text after the caret (used by the trailing-duplication filter).
    let trailingText: String
    /// When `false`, the normalizer keeps only the first line of the completion.
    let isMultiLine: Bool
    let maxTokens: Int
    let temperature: Double
    let topP: Double
    let topK: Int
    let minP: Double
    let repeatPenalty: Double
    let seed: Int
    /// Monotonic freshness token — the coordinator drops results whose
    /// generation no longer matches the live focus.
    let generation: UInt64
    /// True when the caret is strictly inside a word (Cotabby's
    /// `forceWordContinuation`): the completion must continue the current word.
    /// Enforced at the output layer by `CotypingTextNormalizer`.
    var forceWordContinuation: Bool = false

    /// `true` when the caret prefix ends on whitespace, so the normalizer drops
    /// a leading space the model may add (deterministic space management).
    var precedingEndsWithWhitespace: Bool {
        prefixText.last.map { $0.isWhitespace } ?? false
    }
}

/// An active suggestion: the field it was generated against, the full completion,
/// and how much of it the user has already accepted (in Characters). Accepting a
/// word advances `consumedCount`; the overlay then shows only `remainingText`.
struct CotypingSession: Equatable, Sendable {
    let field: CotypingField
    let fullText: String
    var consumedCount: Int = 0

    var acceptedText: String { String(fullText.prefix(consumedCount)) }
    var remainingText: String { String(fullText.dropFirst(consumedCount)) }
    var isExhausted: Bool { consumedCount >= fullText.count }

    func advanced(by count: Int) -> CotypingSession {
        var copy = self
        copy.consumedCount = min(fullText.count, consumedCount + count)
        return copy
    }
}

/// Coordinator-published state, surfaced in the in-app Cotyping section for live
/// status and diagnostics.
enum CotypingState: Equatable, Sendable {
    case idle
    case disabled(String)
    case debouncing
    case generating
    case ready(text: String)
    case failed(String)

    var label: String {
        switch self {
        case .idle: "Idle"
        case .disabled(let why): why
        case .debouncing: "Waiting for you to pause…"
        case .generating: "Thinking…"
        case .ready(let text): "Suggesting: \(text)"
        case .failed(let why): "Error: \(why)"
        }
    }
}
