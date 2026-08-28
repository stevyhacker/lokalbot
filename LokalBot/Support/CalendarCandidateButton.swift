import AppKit
import SwiftUI

/// A native macOS button for one calendar-backed speaker identity. SwiftUI's
/// custom-label buttons can surface the identifier on a child AX element in a
/// sheet; this narrow bridge guarantees one actionable `AXButton` containing
/// both the attendee name and email address.
struct CalendarCandidateButton: NSViewRepresentable {
    let title: String
    let systemImageName: String
    let accessibilityIdentifier: String
    let isSelected: Bool
    let isEnabled: Bool
    let action: () -> Void

    func makeNSView(context: Context) -> CalendarCandidateButtonContainer {
        CalendarCandidateButtonContainer()
    }

    func updateNSView(
        _ container: CalendarCandidateButtonContainer,
        context: Context
    ) {
        container.update(
            title: title,
            systemImageName: systemImageName,
            accessibilityIdentifier: accessibilityIdentifier,
            isSelected: isSelected,
            isEnabled: isEnabled,
            action: action)
    }
}

/// SwiftUI treats the root view returned by `NSViewRepresentable` as its own
/// accessibility boundary. Keep that root non-accessible and explicitly vend
/// the actionable native child so AX clients see one real button in sheets.
final class CalendarCandidateButtonContainer: NSView {
    let button = CalendarCandidateButtonControl()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override var intrinsicContentSize: NSSize {
        button.intrinsicContentSize
    }

    func update(
        title: String,
        systemImageName: String,
        accessibilityIdentifier: String,
        isSelected: Bool,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) {
        button.update(
            title: title,
            systemImageName: systemImageName,
            accessibilityIdentifier: accessibilityIdentifier,
            isSelected: isSelected,
            isEnabled: isEnabled,
            action: action)
        invalidateIntrinsicContentSize()
    }

    private func configure() {
        setAccessibilityElement(false)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityChildren([button])
    }
}

final class CalendarCandidateButtonControl: NSButton {
    private var activation: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        target = self
        action = #selector(activate(_:))
        setButtonType(.momentaryPushIn)
        isBordered = false
        imagePosition = .imageLeading
        alignment = .left
        lineBreakMode = .byTruncatingTail
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        target = self
        action = #selector(activate(_:))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    func update(
        title: String,
        systemImageName: String,
        accessibilityIdentifier: String,
        isSelected: Bool,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) {
        self.title = title
        image = NSImage(
            systemSymbolName: systemImageName,
            accessibilityDescription: nil)
        contentTintColor = isSelected ? .controlAccentColor : .labelColor
        self.isEnabled = isEnabled
        toolTip = title
        activation = action
        setAccessibilityIdentifier(accessibilityIdentifier)
        setAccessibilityLabel(title)
    }

    @objc private func activate(_ sender: NSButton) {
        activation?()
    }
}
