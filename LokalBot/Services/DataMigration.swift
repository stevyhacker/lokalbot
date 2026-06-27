import Foundation
import Security

/// One-shot migration from the previous **LokalBotV2** identity to **LokalBotV3**.
///
/// The V3 rename bumped the bundle id (`com.dotenv.LokalBotV2` → `…V3`), which
/// re-keys every identity-scoped store at once:
///   • the Application Support data dir   (`…/com.dotenv.LokalBot{V2,V3}/`)
///   • the login Keychain                 (service == bundle id)
///   • UserDefaults                       (the per-bundle-id preference domain)
///
/// Without migration a rename would look like total data loss: an empty library,
/// reset settings, and — worst — screenshots that can no longer be decrypted
/// because the AES key lived under the old service. This copies all three forward
/// on the first V3 launch.
///
/// MUST run at the very top of process `main()` — before `AppSettings.load()`,
/// `StorageManager()`, or any Keychain read — so the V3 stores observe migrated
/// values and `StorageManager` doesn't create an empty V3 dir first.
///
/// The embedded `lokalbot-cli` is a separate binary and does NOT run this; it
/// reads whatever the app has already migrated. The normal flow launches the app
/// (which migrates) before the CLI is used.
enum DataMigration {

    // MARK: Old (V2) identity — literals on purpose; these names are frozen history.
    private static let oldBundleID = "com.dotenv.LokalBotV2"
    private static let oldSettingsKey = "lokalbotv2.settings"
    private static let oldOnboardingKey = "lokalbotv2.onboarding.shown"
    private static let oldDBName = "lokalbotv2.sqlite"

    /// New DB filename — mirrors the `databaseURL` built in `AppState`.
    private static let newDBName = "lokalbotv3.sqlite"

    /// Generic-password accounts to carry over (service is the bundle id).
    /// `screenshot-key` is the AES-GCM key that decrypts the screenshot filmstrip
    /// — losing it makes existing shots unreadable, so it matters most.
    private static let keychainAccounts = ["screenshot-key", "openai-compatible-api-key"]

    /// Set once migration has been attempted, so it never re-runs (and never
    /// re-prompts for Keychain access) on later launches.
    private static let doneFlag = "lokalbotv3.migratedFromV2"

    /// Migrate the V2 library/settings/secrets into the V3 identity exactly once.
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

        guard !defaults.bool(forKey: doneFlag) else { return }
        // Mark done up front: a partial migration is better than an infinite
        // retry loop that re-shows the Keychain-access dialog every launch.
        defaults.set(true, forKey: doneFlag)

        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let moved = migrateDataDir(from: appSupport.appendingPathComponent(oldBundleID, isDirectory: true),
                                   to: appSupport.appendingPathComponent(AppIdentifiers.bundleID, isDirectory: true))

        if let old = UserDefaults(suiteName: oldBundleID) {
            migrateSettings(from: old, to: defaults)
        }
        migrateKeychain(from: oldBundleID, to: AppIdentifiers.bundleID)

        if moved { NSLog("DataMigration: migrated LokalBotV2 library → \(AppIdentifiers.bundleID)") }
    }

    // MARK: - Data directory

    /// Move the whole V2 library to the V3 location and version-rename the DB.
    /// A move (atomic rename on the same volume) — not a copy — so the multi-GB
    /// model cache isn't duplicated; the V2 keychain secrets are left intact as a
    /// fallback. No-op if there's no V2 library or a V3 one already exists.
    @discardableResult
    static func migrateDataDir(from oldDir: URL, to newDir: URL,
                               fileManager fm: FileManager = .default) -> Bool {
        guard fm.fileExists(atPath: oldDir.path), !fm.fileExists(atPath: newDir.path) else { return false }
        do {
            try fm.moveItem(at: oldDir, to: newDir)
        } catch {
            return false
        }
        // The DB filename embeds the version; rename the file and its WAL/SHM
        // sidecars so the V3 app opens the existing index instead of a fresh one.
        let renames = [(oldDBName, newDBName)] + ["-wal", "-shm"].map { (oldDBName + $0, newDBName + $0) }
        for (old, new) in renames {
            let src = newDir.appendingPathComponent(old)
            guard fm.fileExists(atPath: src.path) else { continue }
            try? fm.moveItem(at: src, to: newDir.appendingPathComponent(new))
        }
        return true
    }

    // MARK: - UserDefaults

    /// Copy the encoded settings blob (raw — the Codable shape is unchanged by the
    /// rename) and the "onboarding shown" flag so a migrated user keeps their
    /// preferences and isn't re-onboarded.
    static func migrateSettings(from old: UserDefaults, to new: UserDefaults) {
        if new.data(forKey: AppSettings.key) == nil,
           let data = old.data(forKey: oldSettingsKey) {
            new.set(data, forKey: AppSettings.key)
        }
        if old.bool(forKey: oldOnboardingKey) {
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
