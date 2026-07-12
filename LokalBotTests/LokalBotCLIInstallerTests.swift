import XCTest
@testable import LokalBot

final class LokalBotCLIInstallerTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var binary: URL!
    private var skillDir: URL!
    private var installer: LokalBotCLIInstaller!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cliinstaller-\(UUID().uuidString)")
        home = root.appendingPathComponent("home")
        let helpers = root.appendingPathComponent(
            "Applications/LokalBot.app/Contents/Helpers")
        skillDir = root.appendingPathComponent(
            "Applications/LokalBot.app/Contents/Resources/lokalbot-cli")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        binary = helpers.appendingPathComponent("lokalbot-cli")
        try Data("#!/bin/sh\n".utf8).write(to: binary)
        try Data("skill".utf8).write(
            to: skillDir.appendingPathComponent("SKILL.md"))

        installer = LokalBotCLIInstaller(
            home: home,
            bundledBinary: binary,
            bundledSkillDir: skillDir,
            fileManager: .default,
            environment: [:])
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    func testInstallCreatesAllThreeSymlinks() throws {
        try installer.install()
        XCTAssertTrue(isSymlink(installer.binLink))
        XCTAssertTrue(isSymlink(installer.skillLink))
        XCTAssertTrue(isSymlink(installer.claudeSkillLink))
        XCTAssertTrue(installer.isInstalled)
    }

    func testInstallIsIdempotent() throws {
        try installer.install()
        try installer.install()
        XCTAssertTrue(installer.isInstalled)
    }

    func testCopyModeCopiesSkillDirsWithMarker() throws {
        try installer.install(skillMode: .copy)
        XCTAssertTrue(isSymlink(installer.binLink))
        for directory in [installer.skillLink, installer.claudeSkillLink] {
            XCTAssertFalse(isSymlink(directory))
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("SKILL.md").path))
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: directory
                    .appendingPathComponent(LokalBotCLIInstaller.copyMarkerName).path))
        }
    }

    func testUninstallRemovesSymlinkInstall() throws {
        try installer.install()
        try installer.uninstall()
        for link in [installer.binLink, installer.skillLink, installer.claudeSkillLink] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: link.path), link.path)
            XCTAssertFalse(isSymlink(link), link.path)
        }
    }

    func testUninstallRemovesCopiedInstall() throws {
        try installer.install(skillMode: .copy)
        try installer.uninstall()
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.skillLink.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.claudeSkillLink.path))
    }

    func testUninstallLeavesForeignFilesAlone() throws {
        try FileManager.default.createDirectory(
            at: installer.binLink.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: installer.binLink,
            withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        try FileManager.default.createDirectory(
            at: installer.claudeSkillLink,
            withIntermediateDirectories: true)
        try Data("mine".utf8).write(
            to: installer.claudeSkillLink.appendingPathComponent("SKILL.md"))

        try installer.uninstall()
        XCTAssertTrue(isSymlink(installer.binLink))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: installer.claudeSkillLink.appendingPathComponent("SKILL.md").path))
    }

    func testFromCurrentBinaryFindsTheBundle() {
        let found = LokalBotCLIInstaller.fromCurrentBinary(path: binary.path)
        XCTAssertNotNil(found)
        XCTAssertEqual(
            found?.bundledBinary?.resolvingSymlinksInPath().path,
            binary.resolvingSymlinksInPath().path)
        XCTAssertEqual(
            found?.bundledSkillDir?.resolvingSymlinksInPath().path,
            skillDir.resolvingSymlinksInPath().path)

        XCTAssertNil(LokalBotCLIInstaller.fromCurrentBinary(
            path: "/tmp/loose-binary"))
    }
}
