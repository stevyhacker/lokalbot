import AppKit
import SwiftUI

/// A compact native control for transcript speaker labels. AppKit owns the hit
/// testing and accessibility role while the attributed title preserves meeting
/// find highlighting. This avoids SwiftUI flattening a plain button inside the
/// nested meeting ScrollView on macOS 15.
struct TranscriptSpeakerButton: NSViewRepresentable {
    let title: String
    let query: String
    let activeMatchIndex: Int?
    let identifier: String
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            title: title,
            target: context.coordinator,
            action: #selector(Coordinator.invoke))
        button.setButtonType(.momentaryPushIn)
        button.isBordered = false
        button.alignment = .left
        button.controlSize = .small
        button.focusRingType = .exterior
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.setAccessibilityIdentifier(identifier)
        button.toolTip = "Rename speaker"
        update(button)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        update(button)
    }

    private func update(_ button: NSButton) {
        button.attributedTitle = Self.attributedTitle(
            title,
            query: query,
            activeMatchIndex: activeMatchIndex)
        button.setAccessibilityLabel(title)
    }

    private static func attributedTitle(
        _ title: String,
        query: String,
        activeMatchIndex: Int?
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(
                    ofSize: NSFont.smallSystemFontSize,
                    weight: .bold),
                .foregroundColor: NSColor.labelColor,
            ])
        for (index, range) in MeetingPageSearch.ranges(
            in: title,
            query: query).enumerated() {
            result.addAttribute(
                .backgroundColor,
                value: index == activeMatchIndex
                    ? NSColor.systemOrange.withAlphaComponent(0.58)
                    : NSColor.systemYellow.withAlphaComponent(0.34),
                range: NSRange(range, in: title))
        }
        return result
    }

    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func invoke() {
            uiTestDiagnosticLog("transcript.speaker native button invoke")
            action()
        }
    }
}
