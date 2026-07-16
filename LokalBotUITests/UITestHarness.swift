import Foundation
import AppKit
import CoreGraphics
import XCTest

enum UITestHarness {
    private static let defaultsKey = "lokalbotv3.settings"
    private static let appBundleIdentifier = "me.dotenv.LokalBot.uitesthost"
    private static let uiTestEnabledKey = "lokalbot.uiTest.enabled"
    private static let uiTestStorageRootKey = "lokalbot.uiTest.storageRoot"
    private static let uiTestDefaultsSuiteKey = "lokalbot.uiTest.defaultsSuite"
    private static let gettingStartedDismissedKey = "lokalbotv3.gettingStartedDismissed"

    struct Launch {
        let app: XCUIApplication
        let defaultsSuiteName: String
    }

    static func launch(
        storageRoot: URL,
        suitePrefix: String,
        settingsJSON: String = defaultSettingsJSON,
        environment: [String: String] = [:],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Launch {
        let suiteName = "me.dotenv.LokalBotUITests.\(suitePrefix).\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName), file: file, line: line)
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(Data(settingsJSON.utf8), forKey: defaultsKey)
        _ = CFPreferencesAppSynchronize(suiteName as CFString)
        seedAppLaunchDefaults(storageRoot: storageRoot, defaultsSuiteName: suiteName)

        let app = try launchAndVerify(
            storageRoot: storageRoot,
            defaultsSuiteName: suiteName,
            environment: environment,
            file: file,
            line: line)

        return Launch(app: app, defaultsSuiteName: suiteName)
    }

    static func relaunch(
        storageRoot: URL,
        defaultsSuiteName: String,
        environment: [String: String] = [:],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> XCUIApplication {
        seedAppLaunchDefaults(storageRoot: storageRoot, defaultsSuiteName: defaultsSuiteName)
        return try launchAndVerify(
            storageRoot: storageRoot,
            defaultsSuiteName: defaultsSuiteName,
            environment: environment,
            file: file,
            line: line)
    }

    private static func launchAndVerify(
        storageRoot: URL,
        defaultsSuiteName: String,
        environment: [String: String],
        file: StaticString,
        line: UInt
    ) throws -> XCUIApplication {
        terminateRunningApp()

        let app = try launchApplication(
            storageRoot: storageRoot,
            defaultsSuiteName: defaultsSuiteName,
            environment: environment,
            file: file,
            line: line)

        let runningApp = try XCTUnwrap(
            waitForRunningApp(timeout: 8),
            "LokalBot UI Test Host did not appear in NSRunningApplication",
            file: file,
            line: line)
        XCTAssertEqual(runningApp.bundleIdentifier, appBundleIdentifier,
                       "Launched unexpected application bundle",
                       file: file, line: line)
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 4)
                || app.wait(for: .runningBackground, timeout: 8),
            "LokalBot UI Test Host did not launch", file: file, line: line)
        XCTAssertTrue(
            waitForVisibleWindow(processIdentifier: runningApp.processIdentifier, timeout: 8),
            "LokalBot UI Test Host did not create a visible native window",
            file: file,
            line: line)
        return app
    }

    static func cleanUp(defaultsSuiteName: String?) {
        if let defaultsSuiteName {
            UserDefaults().removePersistentDomain(forName: defaultsSuiteName)
        }
        let appID = appBundleIdentifier as CFString
        CFPreferencesSetAppValue(uiTestEnabledKey as CFString, nil, appID)
        CFPreferencesSetAppValue(uiTestStorageRootKey as CFString, nil, appID)
        CFPreferencesSetAppValue(uiTestDefaultsSuiteKey as CFString, nil, appID)
        CFPreferencesSetAppValue(gettingStartedDismissedKey as CFString, nil, appID)
        _ = CFPreferencesAppSynchronize(appID)
    }

    static func clickSidebar(
        _ id: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for query in [app.buttons, app.cells, app.staticTexts] where query[id].waitForExistence(timeout: 3) {
            let element = query[id]
            if element.isHittable {
                element.click()
                return
            }
        }
        let fallback = app.descendants(matching: .any)[id]
        XCTAssertTrue(fallback.waitForExistence(timeout: 4),
                      "sidebar item \(id) not found", file: file, line: line)
        fallback.click()
    }

    static func staticText(containing fragment: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@",
                        fragment, fragment))
            .firstMatch
    }

    static func typeInFirstTextField(
        _ text: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let field = app.textFields["settings.search"].exists
            ? app.textFields["settings.search"]
            : app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 6),
                      "text field missing", file: file, line: line)
        let layoutDeadline = Date().addingTimeInterval(4)
        while field.frame.width < 40, Date() < layoutDeadline { usleep(150_000) }
        field.click()
        field.typeText(text)
    }

    private static let defaultSettingsJSON = """
    {
      "menuBarOnly": false,
      "trackingEnabled": true,
      "screenshotsEnabled": false,
      "calendarDetectionEnabled": false,
      "semanticSearchEnabled": false,
      "cotypingEnabled": false
    }
    """

    private static func launchApplication(
        storageRoot: URL,
        defaultsSuiteName: String,
        environment: [String: String],
        file: StaticString,
        line: UInt
    ) throws -> XCUIApplication {
        let appURL = try hostAppURL(file: file, line: line)
        let executableURL = appURL
            .appendingPathComponent("Contents/MacOS/LokalBot UI Test Host")
        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: executableURL.path),
            "LokalBot UI Test Host executable missing at \(executableURL.path)",
            file: file,
            line: line)

        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "--lokalbot-ui-test",
            "--lokalbot-storage-root", storageRoot.path,
            "--lokalbot-defaults-suite", defaultsSuiteName,
        ]
        process.environment = appHostEnvironment().merging([
            "LOKALBOT_UI_TEST": "1",
            "LOKALBOT_STORAGE_ROOT": storageRoot.path,
            "LOKALBOT_DEFAULTS_SUITE": defaultsSuiteName,
        ]) { _, new in new }.merging(environment) { _, new in new }
        try process.run()

        return XCUIApplication(bundleIdentifier: appBundleIdentifier)
    }

    private static func appHostEnvironment() -> [String: String] {
        let source = ProcessInfo.processInfo.environment
        var environment: [String: String] = [:]
        for key in ["HOME", "TMPDIR", "PATH", "USER", "LOGNAME", "LANG", "SHELL"] {
            if let value = source[key], !value.isEmpty {
                environment[key] = value
            }
        }
        return environment
    }

    private static func hostAppURL(file: StaticString, line: UInt) throws -> URL {
        let productsDirectory = Bundle.main.bundleURL.deletingLastPathComponent()
        let appURL = productsDirectory.appendingPathComponent("LokalBot UI Test Host.app")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: appURL.path),
            "LokalBot UI Test Host app missing at \(appURL.path)",
            file: file,
            line: line)
        return appURL
    }

    private static func seedAppLaunchDefaults(storageRoot: URL, defaultsSuiteName: String) {
        let appID = appBundleIdentifier as CFString
        CFPreferencesSetAppValue(uiTestEnabledKey as CFString, kCFBooleanTrue, appID)
        CFPreferencesSetAppValue(uiTestStorageRootKey as CFString, storageRoot.path as CFString, appID)
        CFPreferencesSetAppValue(uiTestDefaultsSuiteKey as CFString, defaultsSuiteName as CFString, appID)
        _ = CFPreferencesAppSynchronize(appID)
    }

    private static func waitForVisibleWindow(
        processIdentifier: pid_t,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if hasVisibleWindow(processIdentifier: processIdentifier) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    private static func hasVisibleWindow(processIdentifier: pid_t) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID) as? [[String: Any]] else {
            return false
        }

        return windows.contains { info in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processIdentifier,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 else {
                return false
            }
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0
            guard alpha > 0 else { return false }

            let bounds = info[kCGWindowBounds as String] as? [String: Any]
            let width = (bounds?["Width"] as? NSNumber)?.doubleValue ?? 0
            let height = (bounds?["Height"] as? NSNumber)?.doubleValue ?? 0
            return width >= 200 && height >= 200
        }
    }

    private static func waitForRunningApp(timeout: TimeInterval) -> NSRunningApplication? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let app = NSRunningApplication
                .runningApplications(withBundleIdentifier: appBundleIdentifier)
                .first(where: { !$0.isTerminated }) {
                return app
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return nil
    }

    private static func terminateRunningApp() {
        for runningApp in NSRunningApplication
            .runningApplications(withBundleIdentifier: appBundleIdentifier) {
            runningApp.terminate()
            let deadline = Date().addingTimeInterval(4)
            while !runningApp.isTerminated, Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
            if !runningApp.isTerminated {
                runningApp.forceTerminate()
            }
        }
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            let stillRunning = NSRunningApplication
                .runningApplications(withBundleIdentifier: appBundleIdentifier)
                .contains { !$0.isTerminated }
            if !stillRunning { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }
}
