import CoreGraphics
import Foundation

/// Derives the string keys that identify "the same field" across focus
/// snapshots. All field-identity derivations live here so the schemes cannot
/// drift apart between the anchor cache, prewarm dedupe, and reconciliation.
enum CotypingFieldIdentity {

    /// Identity for anchoring a suggestion to one concrete focused field across
    /// host publishes. The AX identity is the strongest signal; apps that do not
    /// expose one fall back to the field frame, then surface metadata. Content is
    /// deliberately excluded so typing through a suggestion keeps the anchor.
    static func suggestionAnchor(for field: CotypingField) -> String {
        fieldIdentity(for: field)
    }

    /// Identity for deduplicating engine prewarms per focused field. Prefers
    /// the AX focus identity, falls back to the input frame, then to
    /// window/placeholder text.
    static func prewarm(for field: CotypingField) -> String {
        fieldIdentity(for: field)
    }

    private static func fieldIdentity(for field: CotypingField) -> String {
        let fieldPart: String
        if let focusIdentityKey = field.focusIdentityKey, !focusIdentityKey.isEmpty {
            fieldPart = "focus:\(focusIdentityKey)"
        } else if let frame = field.inputFrameRect {
            fieldPart = "frame:\(roundedRectIdentity(frame))"
        } else {
            fieldPart = [
                field.windowTitle ?? "",
                field.fieldPlaceholder ?? "",
            ].joined(separator: "\u{1f}")
        }
        return [
            String(field.processID),
            field.bundleID ?? "",
            field.appName,
            field.role,
            fieldPart,
        ].joined(separator: "\u{1f}")
    }

    private static func roundedRectIdentity(_ rect: CGRect) -> String {
        [
            rect.origin.x,
            rect.origin.y,
            rect.size.width,
            rect.size.height,
        ]
            .map { String(Int($0.rounded())) }
            .joined(separator: ",")
    }
}
