import XCTest
@testable import LokalBot

/// Migration from old LokalBot identities. Exercises the data-loss-prone
/// filesystem/settings halves with injected dirs/suites (the Keychain half talks
/// to the real login keychain, so it's verified on install, not here).
final class DataMigrationTests: XCTestCase {

    private var tmp: URL!
    private var suites: [String] = []

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("datamig-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
        for name in suites { UserDefaults().removePersistentDomain(forName: name) }
        suites = []
    }

    private func freshSuite() -> UserDefaults {
        let name = "datamig.test.\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    private func makeDatabase(at url: URL, rows: Int = 0,
                              activityRows: Int = 0,
                              indexedMeetings: Int = 0,
                              payloadBytes: Int = 0) throws {
        let database = try XCTUnwrap(SQLiteDatabase(url: url))
        database.exec("""
            CREATE TABLE IF NOT EXISTS screenshots (
                id INTEGER PRIMARY KEY, ts REAL NOT NULL, path TEXT NOT NULL, app TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS activity_blocks (
                app TEXT NOT NULL, title TEXT NOT NULL, start REAL NOT NULL, end REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS indexed_meetings (
                meeting_id TEXT PRIMARY KEY, source_mtime REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS docs (text TEXT NOT NULL);
            """)
        for index in 0..<rows {
            database.run("INSERT INTO screenshots (ts, path, app) VALUES (?1, ?2, ?3)",
                         bind: [Double(index), "shot-\(index).jpg", "Tests"])
        }
        for index in 0..<activityRows {
            database.run("INSERT INTO activity_blocks (app, title, start, end) VALUES (?1, ?2, ?3, ?4)",
                         bind: ["Tests", "Window \(index)", Double(index), Double(index + 1)])
        }
        for index in 0..<indexedMeetings {
            database.run("INSERT INTO indexed_meetings (meeting_id, source_mtime) VALUES (?1, ?2)",
                         bind: [UUID().uuidString, Double(index)])
            database.run("INSERT INTO docs (text) VALUES (?1)", bind: ["Indexed meeting \(index)"])
        }
        if payloadBytes > 0 {
            database.exec("CREATE TABLE IF NOT EXISTS payload (data BLOB NOT NULL);")
            database.run("INSERT INTO payload (data) VALUES (?1)",
                         bind: [Data(repeating: 7, count: payloadBytes)])
        }
    }

    // MARK: - Data directory

    func testMigrateDataDirMovesLibraryAndVersionRenamesDatabase() throws {
        let fm = FileManager.default
        let oldDir = tmp.appendingPathComponent("com.dotenv.LokalBotV2", isDirectory: true)
        let newDir = tmp.appendingPathComponent("me.dotenv.LokalBot", isDirectory: true)
        let meetings = oldDir.appendingPathComponent("meetings/2026/06", isDirectory: true)
        try fm.createDirectory(at: meetings, withIntermediateDirectories: true)
        try Data("meta".utf8).write(to: meetings.appendingPathComponent("meta.json"))
        // DB + its WAL/SHM sidecars carry the old version in the filename.
        for name in ["lokalbotv2.sqlite", "lokalbotv2.sqlite-wal", "lokalbotv2.sqlite-shm"] {
            try Data("db".utf8).write(to: oldDir.appendingPathComponent(name))
        }

        XCTAssertTrue(DataMigration.migrateDataDir(from: oldDir, to: newDir))

        XCTAssertFalse(fm.fileExists(atPath: oldDir.path), "V2 dir should be moved, not left behind")
        // Library content survives the move.
        XCTAssertTrue(fm.fileExists(atPath: newDir.appendingPathComponent("meetings/2026/06/meta.json").path))
        // DB + sidecars are renamed to the V3 filename the app opens.
        for name in ["lokalbotv3.sqlite", "lokalbotv3.sqlite-wal", "lokalbotv3.sqlite-shm"] {
            XCTAssertTrue(fm.fileExists(atPath: newDir.appendingPathComponent(name).path), "\(name) missing")
        }
        // No stale V2-named DB lingers in the migrated dir.
        XCTAssertFalse(fm.fileExists(atPath: newDir.appendingPathComponent("lokalbotv2.sqlite").path))
    }

    func testMigrateDataDirMovesV3LibraryWithoutRenamingDatabase() throws {
        let fm = FileManager.default
        let oldDir = tmp.appendingPathComponent(["com", "dotenv", "LokalBotV3"].joined(separator: "."),
                                                isDirectory: true)
        let newDir = tmp.appendingPathComponent("me.dotenv.LokalBot", isDirectory: true)
        try fm.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try Data("db".utf8).write(to: oldDir.appendingPathComponent("lokalbotv3.sqlite"))

        XCTAssertTrue(DataMigration.migrateDataDir(from: oldDir, to: newDir, renamesDatabase: false))

        XCTAssertFalse(fm.fileExists(atPath: oldDir.path))
        XCTAssertTrue(fm.fileExists(atPath: newDir.appendingPathComponent("lokalbotv3.sqlite").path))
    }

    func testMigrateDataDirMergesV3LibraryIntoExistingPlaceholder() throws {
        let fm = FileManager.default
        let oldDir = tmp.appendingPathComponent(["com", "dotenv", "LokalBotV3"].joined(separator: "."),
                                                isDirectory: true)
        let newDir = tmp.appendingPathComponent("me.dotenv.LokalBot", isDirectory: true)
        try fm.createDirectory(at: oldDir.appendingPathComponent("models"), withIntermediateDirectories: true)
        try fm.createDirectory(at: newDir.appendingPathComponent("meetings"), withIntermediateDirectories: true)
        try makeDatabase(at: oldDir.appendingPathComponent("lokalbotv3.sqlite"), rows: 1)
        try makeDatabase(at: newDir.appendingPathComponent("lokalbotv3.sqlite"))
        try Data("model".utf8).write(to: oldDir.appendingPathComponent("models/local.gguf"))

        XCTAssertTrue(DataMigration.migrateDataDir(from: oldDir, to: newDir,
                                                   renamesDatabase: false,
                                                   mergeIfDestinationExists: true,
                                                   replacePlaceholderDatabase: true))

        XCTAssertTrue(fm.fileExists(atPath: newDir.appendingPathComponent("models/local.gguf").path))
        XCTAssertEqual(SQLiteDatabase(url: newDir.appendingPathComponent("lokalbotv3.sqlite"))?
            .firstDouble("SELECT COUNT(*) FROM screenshots"), 1)
    }

    func testMigrateDataDirDoesNotReplaceUsefulExistingV3Database() throws {
        let fm = FileManager.default
        let oldDir = tmp.appendingPathComponent(["com", "dotenv", "LokalBotV3"].joined(separator: "."),
                                                isDirectory: true)
        let newDir = tmp.appendingPathComponent("me.dotenv.LokalBot", isDirectory: true)
        try fm.createDirectory(at: oldDir.appendingPathComponent("models"), withIntermediateDirectories: true)
        try fm.createDirectory(at: newDir, withIntermediateDirectories: true)
        try makeDatabase(at: oldDir.appendingPathComponent("lokalbotv3.sqlite"), rows: 2)
        try makeDatabase(at: newDir.appendingPathComponent("lokalbotv3.sqlite"), rows: 1)
        try Data("model".utf8).write(to: oldDir.appendingPathComponent("models/local.gguf"))

        XCTAssertTrue(DataMigration.migrateDataDir(from: oldDir, to: newDir,
                                                   renamesDatabase: false,
                                                   mergeIfDestinationExists: true,
                                                   replacePlaceholderDatabase: true))

        XCTAssertTrue(fm.fileExists(atPath: newDir.appendingPathComponent("models/local.gguf").path))
        XCTAssertEqual(SQLiteDatabase(url: newDir.appendingPathComponent("lokalbotv3.sqlite"))?
            .firstDouble("SELECT COUNT(*) FROM screenshots"), 1)
    }

    func testMigrateDataDirReplacesSmallRegeneratedV3DatabaseWhenOldHasCaptureHistory() throws {
        let fm = FileManager.default
        let oldDir = tmp.appendingPathComponent(["com", "dotenv", "LokalBotV3"].joined(separator: "."),
                                                isDirectory: true)
        let newDir = tmp.appendingPathComponent("me.dotenv.LokalBot", isDirectory: true)
        try fm.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: newDir, withIntermediateDirectories: true)
        try makeDatabase(at: oldDir.appendingPathComponent("lokalbotv3.sqlite"),
                         rows: 2,
                         activityRows: 150,
                         payloadBytes: 600 * 1024)
        try makeDatabase(at: newDir.appendingPathComponent("lokalbotv3.sqlite"),
                         activityRows: 2,
                         indexedMeetings: 5)

        XCTAssertTrue(DataMigration.migrateDataDir(from: oldDir, to: newDir,
                                                   renamesDatabase: false,
                                                   mergeIfDestinationExists: true,
                                                   replacePlaceholderDatabase: true))

        let migratedDB = SQLiteDatabase(url: newDir.appendingPathComponent("lokalbotv3.sqlite"))
        XCTAssertEqual(migratedDB?.firstDouble("SELECT COUNT(*) FROM screenshots"), 2)
        XCTAssertEqual(migratedDB?.firstDouble("SELECT COUNT(*) FROM activity_blocks"), 150)
    }

    func testMigrateDataDirIsNoOpWhenV3AlreadyExists() throws {
        let fm = FileManager.default
        let oldDir = tmp.appendingPathComponent("com.dotenv.LokalBotV2", isDirectory: true)
        let newDir = tmp.appendingPathComponent("me.dotenv.LokalBot", isDirectory: true)
        try fm.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: oldDir.appendingPathComponent("marker"))
        try fm.createDirectory(at: newDir, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: newDir.appendingPathComponent("keep"))

        XCTAssertFalse(DataMigration.migrateDataDir(from: oldDir, to: newDir),
                       "must not clobber an existing V3 library")
        XCTAssertTrue(fm.fileExists(atPath: oldDir.appendingPathComponent("marker").path))
        XCTAssertTrue(fm.fileExists(atPath: newDir.appendingPathComponent("keep").path))
    }

    func testMigrateDataDirIsNoOpWithoutV2Library() {
        let oldDir = tmp.appendingPathComponent("com.dotenv.LokalBotV2", isDirectory: true)
        let newDir = tmp.appendingPathComponent("me.dotenv.LokalBot", isDirectory: true)
        XCTAssertFalse(DataMigration.migrateDataDir(from: oldDir, to: newDir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: newDir.path))
    }

    // MARK: - Settings / UserDefaults

    func testMigrateSettingsCopiesBlobAndOnboardingFlag() throws {
        let old = freshSuite(), new = freshSuite()
        var settings = AppSettings()
        settings.retentionDays = 99          // a clearly non-default value to track
        settings.menuBarOnly = false
        old.set(try JSONEncoder().encode(settings), forKey: "lokalbotv2.settings")
        old.set(true, forKey: "lokalbotv2.onboarding.shown")

        DataMigration.migrateSettings(from: old, to: new)

        let data = try XCTUnwrap(new.data(forKey: AppSettings.key), "settings blob not copied")
        let migrated = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(migrated.retentionDays, 99)
        XCTAssertFalse(migrated.menuBarOnly)
        XCTAssertTrue(new.bool(forKey: AppState.onboardingShownKey), "onboarding flag not carried over")
    }

    func testMigrateSettingsDoesNotOverwriteExistingV3Settings() throws {
        let old = freshSuite(), new = freshSuite()
        var oldSettings = AppSettings(); oldSettings.retentionDays = 99
        old.set(try JSONEncoder().encode(oldSettings), forKey: "lokalbotv2.settings")
        var newSettings = AppSettings(); newSettings.retentionDays = 7
        new.set(try JSONEncoder().encode(newSettings), forKey: AppSettings.key)

        DataMigration.migrateSettings(from: old, to: new)

        let data = try XCTUnwrap(new.data(forKey: AppSettings.key))
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: data).retentionDays, 7,
                       "existing V3 settings must win over a stale V2 copy")
    }

    func testMigrateSettingsCopiesCurrentIdentityKeys() throws {
        let old = freshSuite(), new = freshSuite()
        var settings = AppSettings()
        settings.retentionDays = 42
        old.set(try JSONEncoder().encode(settings), forKey: AppSettings.key)
        old.set(true, forKey: AppState.onboardingShownKey)

        DataMigration.migrateSettings(from: old, to: new,
                                      settingsKey: AppSettings.key,
                                      onboardingKey: AppState.onboardingShownKey)

        let data = try XCTUnwrap(new.data(forKey: AppSettings.key))
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: data).retentionDays, 42)
        XCTAssertTrue(new.bool(forKey: AppState.onboardingShownKey))
    }

    // MARK: - Test-host guard (regression: `xcodebuild test` must not move real data)

    func testRunIfNeededIsNoOpUnderXCTestHost() {
        // Running the app as a unit-test host executes main() and thus
        // runIfNeeded; the XCTestConfigurationFilePath guard must make it bail
        // before it marks itself done or touches the real user library.
        let defaults = freshSuite()
        DataMigration.runIfNeeded(
            environment: ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"],
            defaults: defaults)
        XCTAssertFalse(defaults.bool(forKey: "lokalbotv3.migratedFromV2"),
                       "migration must not run (or mark itself done) under an XCTest host")
    }
}
