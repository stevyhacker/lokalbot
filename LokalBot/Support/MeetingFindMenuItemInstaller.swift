import AppKit

/// Adds the meeting-local Find command immediately before AppKit's standard
/// Command-F item. When disabled, the native text Find item remains available;
/// when enabled, this earlier item routes the same shortcut to meeting search.
enum MeetingFindMenuItemInstaller {
    static let identifier = NSUserInterfaceItemIdentifier(
        "lokalbot.findInMeeting")

    @MainActor
    static func install(
        in mainMenu: NSMenu,
        target: AnyObject,
        action: Selector
    ) -> NSMenuItem? {
        if let existing = existingItem(in: mainMenu) { return existing }
        guard let editMenu = editMenu(in: mainMenu) else { return nil }

        let item = NSMenuItem(
            title: "Find in Meeting…",
            action: action,
            keyEquivalent: "f")
        item.identifier = identifier
        item.keyEquivalentModifierMask = .command
        item.target = target
        item.isEnabled = false

        let nativeFindIndex = editMenu.items.firstIndex(where: isCommandF)
            ?? editMenu.items.endIndex
        editMenu.insertItem(item, at: nativeFindIndex)
        return item
    }

    private static func existingItem(in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.identifier == identifier { return item }
            if let submenu = item.submenu,
               let existing = existingItem(in: submenu) {
                return existing
            }
        }
        return nil
    }

    private static func editMenu(in mainMenu: NSMenu) -> NSMenu? {
        if let edit = mainMenu.items.first(where: { $0.title == "Edit" })?.submenu {
            return edit
        }
        return mainMenu.items.compactMap(\.submenu).first { submenu in
            submenu.items.contains(where: isCommandF)
        }
    }

    private static func isCommandF(_ item: NSMenuItem) -> Bool {
        item.keyEquivalent.lowercased() == "f"
            && item.keyEquivalentModifierMask.intersection(
                [.command, .option, .control, .shift]) == .command
    }
}
