import Foundation
import Security

/// One-shot migrations from previous LokalBot identities to the current app id.
///
/// Bundle-id renames re-key every identity-scoped store at once:
///   • the Application Support data dir   (`~/Library/Application Support/<bundle id>/`)
///   • the login Keychain                 (service == bundle id)
///   • UserDefaults                       (the per-bundle-id preference domain)
///
/// Without migration a rename would look like total data loss: an empty library,
/// reset settings, and — worst — screenshots that can no longer be decrypted
/// because the AES key lived under the old service. This copies all three forward
/// on first launch after a rename.
///
/// MUST run at the very top of process `main()` — before `AppSettings.load()`,
/// `StorageManager()`, or any Keychain read — so the current stores observe
/// migrated values and `StorageManager` doesn't create an empty dir first.
///
/// The embedded `lokalbot-cli` is a separate binary and does NOT run this; it
/// reads whatever the app has already migrated. The normal flow launches the app
/// (which migrates) before the CLI is used.
enum DataMigration {

    // MARK: Old identities. Keep these frozen; changing them would strand data.
    private static let oldV2BundleID = "com.dotenv.LokalBotV2"
    private static let oldV2SettingsKey = "lokalbotv2.settings"
    private static let oldV2OnboardingKey = "lokalbotv2.onboarding.shown"
    private static let oldV2DBName = "lokalbotv2.sqlite"
    private static let oldV3BundleID = ["com", "dotenv", "LokalBotV3"].joined(separator: ".")

    /// New DB filename — mirrors the `databaseURL` built in `AppState`.
    private static let currentDBName = "lokalbotv3.sqlite"

    /// Generic-password accounts to carry over (service is the bundle id).
    /// `screenshot-key` is the AES-GCM key that decrypts the screenshot filmstrip
    /// — losing it makes existing shots unreadable, so it matters most.
    private static let keychainAccounts = ["screenshot-key", "openai-compatible-api-key"]

    /// Set once migration has been attempted, so it never re-runs (and never
    /// re-prompts for Keychain access) on later launches.
    private static let migratedFromV2Flag = "lokalbotv3.migratedFromV2"
    private static let migratedFromV3Flag = "lokalbot.migratedFromDotenvV3"

    /// Migrate old libraries/settings/secrets into the current identity exactly once.
    static func runIfNeeded(environment: [String: String] = ProcessInfo.processInfo.environment,
                            defaults: UserDefaults = .standard) {
        // A unit-test run launches the app as its XCTest host, which still
        // executes main() — never let `xcodebuild test` move the real user
        // library. XCTest sets XCTestConfigurationFilePath in that process.
        if environment["XCTestConfigurationFilePath"] != nil { return }
        // Never migrate under a UI-test / storage-isolation launch either: those
        // point storage at a throwaway dir, so there's no real library to move.
        if let root = environment["LOKALBOTV3_STORAGE_ROOT"], !root.isEmpty { return }
        if let root = defaults.string(forKey: UITestRuntime.storageRootKey), !root.isEmpty { return }
        if environment["LOKALBOTV3_UI_TEST"] == "1"
            || defaults.bool(forKey: UITestRuntime.enabledKey)
            || UITestRuntime.isEnabled {
            return
        }

        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let currentDir = appSupport.appendingPathComponent(AppIdentifiers.bundleID, isDirectory: true)

        migrateFromV3IfNeeded(appSupport: appSupport, currentDir: currentDir, defaults: defaults)
        migrateFromV2IfNeeded(appSupport: appSupport, currentDir: currentDir, defaults: defaults)
    }

    private static func migrateFromV3IfNeeded(appSupport: URL, currentDir: URL, defaults: UserDefaults) {
        guard !defaults.bool(forKey: migratedFromV3Flag) else { return }
        defaults.set(true, forKey: migratedFromV3Flag)

        let moved = migrateDataDir(from: appSupport.appendingPathComponent(oldV3BundleID, isDirectory: true),
                                   to: currentDir,
                                   renamesDatabase: false,
                                   mergeIfDestinationExists: true,
                                   replacePlaceholderDatabase: true)

        if let old = UserDefaults(suiteName: oldV3BundleID) {
            migrateSettings(from: old, to: defaults,
                            settingsKey: AppSettings.key,
                            onboardingKey: AppState.onboardingShownKey)
        }
        migrateKeychain(from: oldV3BundleID, to: AppIdentifiers.bundleID)

        if moved { NSLog("DataMigration: migrated old LokalBotV3 library -> \(AppIdentifiers.bundleID)") }
    }

    private static func migrateFromV2IfNeeded(appSupport: URL, currentDir: URL, defaults: UserDefaults) {
        guard !defaults.bool(forKey: migratedFromV2Flag) else { return }
        // Mark done up front: a partial migration is better than an infinite
        // retry loop that re-shows the Keychain-access dialog every launch.
        defaults.set(true, forKey: migratedFromV2Flag)

        let moved = migrateDataDir(from: appSupport.appendingPathComponent(oldV2BundleID, isDirectory: true),
                                   to: currentDir)

        if let old = UserDefaults(suiteName: oldV2BundleID) {
            migrateSettings(from: old, to: defaults)
        }
        migrateKeychain(from: oldV2BundleID, to: AppIdentifiers.bundleID)

        if moved { NSLog("DataMigration: migrated LokalBotV2 library -> \(AppIdentifiers.bundleID)") }
    }

    // MARK: - Data directory

    /// Move the whole V2 library to the V3 location and version-rename the DB.
    /// A move (atomic rename on the same volume) — not a copy — so the multi-GB
    /// model cache isn't duplicated; the V2 keychain secrets are left intact as a
    /// fallback. No-op if there's no V2 library or a V3 one already exists.
    @discardableResult
    static func migrateDataDir(from oldDir: URL, to newDir: URL,
                               renamesDatabase: Bool = true,
                               mergeIfDestinationExists: Bool = false,
                               replacePlaceholderDatabase: Bool = false,
                               fileManager fm: FileManager = .default) -> Bool {
        guard fm.fileExists(atPath: oldDir.path) else { return false }
        if fm.fileExists(atPath: newDir.path) {
            guard mergeIfDestinationExists else { return false }
            return mergeDataDir(from: oldDir, to: newDir,
                                replacePlaceholderDatabase: replacePlaceholderDatabase,
                                fileManager: fm)
        }
        do {
            try fm.moveItem(at: oldDir, to: newDir)
        } catch {
            return false
        }
        guard renamesDatabase else { return true }
        // The DB filename embeds the version; rename the file and its WAL/SHM
        // sidecars so the current app opens the existing index instead of a fresh one.
        let renames = [(oldV2DBName, currentDBName)] + ["-wal", "-shm"].map { (oldV2DBName + $0, currentDBName + $0) }
        for (old, new) in renames {
            let src = newDir.appendingPathComponent(old)
            guard fm.fileExists(atPath: src.path) else { continue }
            try? fm.moveItem(at: src, to: newDir.appendingPathComponent(new))
        }
        return true
    }

    @discardableResult
    private static func mergeDataDir(from oldDir: URL, to newDir: URL,
                                     replacePlaceholderDatabase: Bool,
                                     fileManager fm: FileManager) -> Bool {
        var migrated = false
        if replacePlaceholderDatabase {
            migrated = replaceCurrentDatabaseIfPlaceholder(from: oldDir, to: newDir, fileManager: fm) || migrated
        }
        guard let items = try? fm.contentsOfDirectory(at: oldDir,
                                                      includingPropertiesForKeys: [.isDirectoryKey],
                                                      options: [.skipsHiddenFiles]) else {
            return migrated
        }
        let databaseNames = [currentDBName, currentDBName + "-wal", currentDBName + "-shm"]
        for item in items {
            if replacePlaceholderDatabase && databaseNames.contains(item.lastPathComponent) { continue }
            let destination = newDir.appendingPathComponent(item.lastPathComponent)
            migrated = mergeItem(from: item, to: destination, fileManager: fm) || migrated
        }
        return migrated
    }

    @discardableResult
    private static func mergeItem(from source: URL, to destination: URL, fileManager fm: FileManager) -> Bool {
        var sourceIsDirectory = ObjCBool(false)
        guard fm.fileExists(atPath: source.path, isDirectory: &sourceIsDirectory) else { return false }

        var destinationIsDirectory = ObjCBool(false)
        guard fm.fileExists(atPath: destination.path, isDirectory: &destinationIsDirectory) else {
            do {
                try fm.moveItem(at: source, to: destination)
                return true
            } catch {
                return false
            }
        }

        guard sourceIsDirectory.boolValue && destinationIsDirectory.boolValue,
              let children = try? fm.contentsOfDirectory(at: source,
                                                         includingPropertiesForKeys: [.isDirectoryKey],
                                                         options: [.skipsHiddenFiles]) else {
            return false
        }
        var migrated = false
        for child in children {
            migrated = mergeItem(from: child,
                                 to: destination.appendingPathComponent(child.lastPathComponent),
                                 fileManager: fm) || migrated
        }
        if (try? fm.contentsOfDirectory(atPath: source.path).isEmpty) == true {
            try? fm.removeItem(at: source)
        }
        return migrated
    }

    @discardableResult
    private static func replaceCurrentDatabaseIfPlaceholder(from oldDir: URL, to newDir: URL,
                                                            fileManager fm: FileManager) -> Bool {
        let oldDB = oldDir.appendingPathComponent(currentDBName)
        let newDB = newDir.appendingPathComponent(currentDBName)
        guard fm.fileExists(atPath: oldDB.path),
              shouldReplaceCurrentDatabase(oldDB: oldDB, newDB: newDB, fileManager: fm),
              databaseLooksUseful(oldDB, fileManager: fm) else {
            return false
        }
        var migrated = false
        for suffix in ["", "-wal", "-shm"] {
            let old = oldDir.appendingPathComponent(currentDBName + suffix)
            guard fm.fileExists(atPath: old.path) else { continue }
            let new = newDir.appendingPathComponent(currentDBName + suffix)
            try? fm.removeItem(at: new)
            do {
                try fm.moveItem(at: old, to: new)
                migrated = true
            } catch {
                return migrated
            }
        }
        return migrated
    }

    private static func shouldReplaceCurrentDatabase(oldDB: URL, newDB: URL,
                                                     fileManager fm: FileManager) -> Bool {
        if databaseLooksPlaceholder(newDB, fileManager: fm) { return true }

        let oldSize = fileSize(oldDB, fileManager: fm)
        let newSize = fileSize(newDB, fileManager: fm)
        guard newSize <= 512 * 1024,
              oldSize >= max(512 * 1024, newSize * 4) else {
            return false
        }

        let oldScreenshots = databaseRowCount(oldDB, table: "screenshots") ?? 0
        let newScreenshots = databaseRowCount(newDB, table: "screenshots") ?? 0
        if newScreenshots == 0 && oldScreenshots > 0 { return true }

        let oldActivity = databaseRowCount(oldDB, table: "activity_blocks") ?? 0
        let newActivity = databaseRowCount(newDB, table: "activity_blocks") ?? 0
        return newActivity <= 10 && oldActivity > 100
    }

    private static func databaseLooksPlaceholder(_ url: URL, fileManager fm: FileManager) -> Bool {
        guard fm.fileExists(atPath: url.path) else { return true }
        if databaseHasUserRows(url) { return false }
        return fileSize(url, fileManager: fm) <= 128 * 1024
    }

    private static func databaseLooksUseful(_ url: URL, fileManager fm: FileManager) -> Bool {
        guard fm.fileExists(atPath: url.path) else { return false }
        if databaseHasUserRows(url) { return true }
        return fileSize(url, fileManager: fm) > 128 * 1024
    }

    private static func databaseHasUserRows(_ url: URL) -> Bool {
        guard let database = SQLiteDatabase(url: url) else { return false }
        for table in ["activity_blocks", "screenshots", "docs", "indexed_meetings", "embeddings", "embedded_meetings"] {
            if (database.firstDouble("SELECT COUNT(*) FROM \(table)") ?? 0) > 0 {
                return true
            }
        }
        return false
    }

    private static func databaseRowCount(_ url: URL, table: String) -> Int? {
        SQLiteDatabase(url: url)?.firstDouble("SELECT COUNT(*) FROM \(table)").map(Int.init)
    }

    private static func fileSize(_ url: URL, fileManager fm: FileManager) -> Int {
        ((try? fm.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.intValue ?? 0
    }

    // MARK: - UserDefaults

    /// Copy the encoded settings blob (raw — the Codable shape is unchanged by the
    /// rename) and the "onboarding shown" flag so a migrated user keeps their
    /// preferences and isn't re-onboarded.
    static func migrateSettings(from old: UserDefaults, to new: UserDefaults,
                                settingsKey: String = oldV2SettingsKey,
                                onboardingKey: String = oldV2OnboardingKey) {
        if new.data(forKey: AppSettings.key) == nil,
           let data = old.data(forKey: settingsKey) {
            new.set(data, forKey: AppSettings.key)
        }
        if old.bool(forKey: onboardingKey) {
            new.set(true, forKey: AppState.onboardingShownKey)
        }
    }

    // MARK: - Keychain

    /// Re-home each generic-password secret under the new service. The cross-app
    /// read of a V2-created item triggers a one-time macOS "allow access" dialog;
    /// once copied, the V3 app owns its own item and reads it silently. Reads are
    /// non-destructive — the V2 items survive as a fallback.
    static func migrateKeychain(from oldService: String, to newService: String) {
        for account in keychainAccounts {
            guard readData(service: newService, account: account) == nil,
                  let data = readData(service: oldService, account: account) else { continue }
            writeData(data, service: newService, account: account)
        }
    }

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func readData(service: String, account: String) -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    private static func writeData(_ data: Data, service: String, account: String) {
        let query = baseQuery(service: service, account: account)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
