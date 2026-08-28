import AppKit
import SwiftUI

/// A view-level responder-chain bridge for the meeting workspace's Command-F.
/// `commands` alone cannot win reliably against AppKit's built-in text Find
/// item, and the explicit AppKit window used by the UI-test host has no SwiftUI
/// scene commands. Keeping the bridge in the workspace hierarchy scopes the
/// override to the one surface that owns meeting search.
struct MeetingFindKeyEquivalentBridge: NSViewRepresentable {
    let onFind: () -> Void

    func makeNSView(context: Context) -> MeetingFindKeyEquivalentView {
        let view = MeetingFindKeyEquivalentView()
        view.onFind = onFind
        return view
    }

    func updateNSView(_ nsView: MeetingFindKeyEquivalentView, context: Context) {
        nsView.onFind = onFind
    }
}

final class MeetingFindKeyEquivalentView: NSView {
    var onFind: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(
            [.command, .option, .control, .shift])
        guard !event.isARepeat,
              event.charactersIgnoringModifiers?.lowercased() == "f",
              modifiers == .command else {
            return super.performKeyEquivalent(with: event)
        }
        onFind?()
        return true
    }
}
