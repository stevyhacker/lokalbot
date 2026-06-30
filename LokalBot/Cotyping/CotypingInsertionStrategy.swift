import Foundation

/// Pure choice of how an accepted suggestion is committed to the host app.
/// Ported from Cotabby's `InsertionStrategy` / `InsertionStrategySelector`.
/// Synthetic Unicode keystrokes are reliable and clipboard-free for the common
/// short, single-line completion, but some apps mishandle a long or multi-line
/// synthetic string; pasting is steadier there. Keeping the decision here
/// (separate from the side-effectful inserter) makes the policy trivially testable.
nonisolated enum CotypingInsertionStrategy: Equatable, Sendable {
    /// Synthesize the text as a Unicode keyboard event (the default, clipboard-free path).
    case keystroke
    /// Place the text on the pasteboard and synthesize Cmd-V. Used when paste
    /// insertion is enabled and the chunk is large or multi-line.
    case paste
}

enum CotypingInsertionStrategySelector {
    /// At or above this many characters a completion is a paste candidate. Short
    /// completions stay on the keystroke path so the clipboard is never touched
    /// for the overwhelmingly common case.
    static let pasteCharacterThreshold = 80

    /// Picks the insertion strategy for `chunk`. A composing IME always uses
    /// paste because synthetic Unicode keystrokes can be reabsorbed into marked
    /// text instead of committing to the host field.
    static func select(
        forChunk chunk: String,
        pasteEnabled: Bool,
        isComposingIMEActive: Bool = false
    ) -> CotypingInsertionStrategy {
        if isComposingIMEActive {
            return .paste
        }
        guard pasteEnabled else { return .keystroke }
        if chunk.contains(where: \.isNewline) { return .paste }
        return chunk.count >= pasteCharacterThreshold ? .paste : .keystroke
    }
}
