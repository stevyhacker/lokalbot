import AppKit
import XCTest
@testable import LokalBot

@MainActor
final class MeetingFindMenuItemInstallerTests: XCTestCase {
    func testInstallsBeforeNativeCommandFAndOnlyOnce() throws {
        let target = NSObject()
        let mainMenu = NSMenu(title: "Main")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let nativeFind = NSMenuItem(
            title: "Find…",
            action: nil,
            keyEquivalent: "f")
        nativeFind.keyEquivalentModifierMask = .command
        editMenu.addItem(nativeFind)

        let installed = try XCTUnwrap(MeetingFindMenuItemInstaller.install(
            in: mainMenu,
            target: target,
            action: NSSelectorFromString("findInMeeting:")))

        XCTAssertEqual(editMenu.index(of: installed), 0)
        XCTAssertEqual(editMenu.index(of: nativeFind), 1)
        XCTAssertEqual(installed.identifier, MeetingFindMenuItemInstaller.identifier)
        XCTAssertEqual(installed.keyEquivalent, "f")
        XCTAssertEqual(installed.keyEquivalentModifierMask, .command)
        XCTAssertTrue(installed.target === target)
        XCTAssertFalse(installed.isEnabled)

        let duplicate = MeetingFindMenuItemInstaller.install(
            in: mainMenu,
            target: target,
            action: NSSelectorFromString("findInMeeting:"))
        XCTAssertTrue(duplicate === installed)
        XCTAssertEqual(editMenu.items.filter {
            $0.identifier == MeetingFindMenuItemInstaller.identifier
        }.count, 1)
    }

    func testCreatesEditMenuWhenSceneCommandsAreUnavailable() throws {
        let mainMenu = NSMenu(title: "Main")
        let item = try XCTUnwrap(MeetingFindMenuItemInstaller.install(
            in: mainMenu,
            target: NSObject(),
            action: NSSelectorFromString("findInMeeting:")))

        let edit = try XCTUnwrap(mainMenu.items.first {
            $0.title == "Edit"
        }?.submenu)
        XCTAssertTrue(edit.items.first === item)
        XCTAssertEqual(item.identifier, MeetingFindMenuItemInstaller.identifier)
    }
}
