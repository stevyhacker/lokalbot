import Foundation
import Security
import CryptoKit

enum AppIdentifiers {
    /// The host LokalBot app's bundle id, used to resolve its Application
    /// Support directory and Keychain consistently from any binary that
    /// belongs to the app (the app itself, the embedded `lokalbot-cli`, …).
    /// Hard-coded so the CLI process — whose own bundle id differs from
    /// the app's — still reads/writes the same paths.
    static let appBundleID = "me.dotenv.LokalBot"

    static var bundleID: String { appBundleID }
}

enum UITestRuntime {
    static let enabledKey = "lokalbot.uiTest.enabled"
    static let storageRootKey = "lokalbot.uiTest.storageRoot"
    static let defaultsSuiteKey = "lokalbot.uiTest.defaultsSuite"
    private static let enabledArgument = "--lokalbot-ui-test"
    private static let storageRootArgument = "--lokalbot-storage-root"
    private static let defaultsSuiteArgument = "--lokalbot-defaults-suite"

    /// XCTest loads the production app as its host, so `LokalBotMain.main()` and
    /// `AppState` still run before the first test method. Keep that launch
    /// hermetic even when the caller did not provide the UI-test overrides.
    static var isUnitTesting: Bool {
        !isEnabled
            && ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    static var isEnabled: Bool {
#if LOKALBOT_UI_TEST_HOST
        true
#else
        ProcessInfo.processInfo.environment["LOKALBOT_UI_TEST"] == "1"
            || ProcessInfo.processInfo.arguments.contains(enabledArgument)
            || UserDefaults.standard.bool(forKey: enabledKey)
#endif
    }

    static var storageRoot: String? {
        nonEmpty(ProcessInfo.processInfo.environment["LOKALBOT_STORAGE_ROOT"])
            ?? argumentValue(after: storageRootArgument)
            ?? nonEmpty(UserDefaults.standard.string(forKey: storageRootKey))
            ?? unitTestStorageRoot
    }

    static var defaultsSuiteName: String? {
        nonEmpty(ProcessInfo.processInfo.environment["LOKALBOT_DEFAULTS_SUITE"])
            ?? argumentValue(after: defaultsSuiteArgument)
            ?? nonEmpty(UserDefaults.standard.string(forKey: defaultsSuiteKey))
            ?? unitTestDefaultsSuite
    }

    private static var unitTestStorageRoot: String? {
        guard isUnitTesting else { return nil }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("lokalbot-unit-tests-\(ProcessInfo.processInfo.processIdentifier)",
                                    isDirectory: true)
            .path
    }

    private static var unitTestDefaultsSuite: String? {
        guard isUnitTesting else { return nil }
        return "me.dotenv.LokalBot.unit-tests.\(ProcessInfo.processInfo.processIdentifier)"
    }

    private static func argumentValue(after option: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: option),
              arguments.indices.contains(arguments.index(after: index)) else {
            return nil
        }
        return nonEmpty(arguments[arguments.index(after: index)])
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

enum KeychainSecrets {
    private enum KeychainFailure: LocalizedError {
        case operation(String, account: String, status: OSStatus)
        case invalidData(account: String)
        case verification(account: String)

        var errorDescription: String? {
            switch self {
            case .operation(let operation, let account, let status):
                let detail = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
                return "Could not \(operation) the \(account) Keychain item (\(detail))."
            case .invalidData(let account):
                return "The \(account) Keychain item contains invalid data."
            case .verification(let account):
                return "The \(account) Keychain item could not be verified after saving."
            }
        }
    }

    static func string(account: String) throws -> String? {
        guard let data = try data(account: account) else { return nil }
        guard let value = String(data: data, encoding: .utf8) else {
            throw KeychainFailure.invalidData(account: account)
        }
        return value
    }

    static func data(account: String) throws -> Data? {
        try data(service: AppIdentifiers.bundleID, account: account)
    }

    static func setString(_ value: String, account: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try delete(account: account)
        } else {
            try set(Data(trimmed.utf8), account: account)
        }
    }

    static func set(_ data: Data, account: String) throws {
        try set(data, service: AppIdentifiers.bundleID, account: account)
    }

    /// Copy a secret between app identities without exposing low-level
    /// Security.framework queries to migration code. Existing destination
    /// values always win, and source items remain untouched as a fallback.
    static func copyIfMissing(
        account: String,
        fromService oldService: String,
        toService newService: String
    ) throws {
        guard try data(service: newService, account: account) == nil,
              let source = try data(service: oldService, account: account) else {
            return
        }
        try set(source, service: newService, account: account)
    }

    private static func set(_ data: Data, service: String, account: String) throws {
        let query = baseQuery(service: service, account: account)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainFailure.operation("save", account: account, status: addStatus)
            }
        } else if status != errSecSuccess {
            throw KeychainFailure.operation("update", account: account, status: status)
        }
        guard try self.data(service: service, account: account) == data else {
            throw KeychainFailure.verification(account: account)
        }
    }

    static func delete(account: String) throws {
        let status = SecItemDelete(
            baseQuery(service: AppIdentifiers.bundleID, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainFailure.operation("delete", account: account, status: status)
        }
    }

    private static func data(service: String, account: String) throws -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var existing: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &existing)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainFailure.operation("read", account: account, status: status)
        }
        guard let data = existing as? Data else {
            throw KeychainFailure.invalidData(account: account)
        }
        return data
    }

    // Security.framework requires a heterogeneous query dictionary.
    private static func baseQuery(service: String, account: String) -> [String: Any] { // swiftlint:disable:this no_dynamic_any
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// A per-install AES-256 key for `account`, generated on first use and
    /// stored in the Keychain (design §3.4). Used to seal at-rest data —
    /// screenshots (`screenshot-key`) and chat history (`chat-key`) — with
    /// `AES.GCM`. Cached in-process per account; `@MainActor` because the cache
    /// is shared mutable state and every caller already runs on the main actor.
    @MainActor private static var symmetricKeyCache: [String: SymmetricKey] = [:]
    @MainActor static func symmetricKey(account: String) throws -> SymmetricKey {
        if let cached = symmetricKeyCache[account] { return cached }
#if LOKALBOT_UI_TEST_HOST
        if UITestRuntime.isEnabled {
            let digest = SHA256.hash(data: Data("lokalbot-ui-test-\(account)".utf8))
            let key = SymmetricKey(data: Data(digest))
            symmetricKeyCache[account] = key
            return key
        }
#endif
        if let data = try data(account: account) {
            let key = SymmetricKey(data: data)
            symmetricKeyCache[account] = key
            return key
        }
        let key = SymmetricKey(size: .bits256)
        try set(key.withUnsafeBytes { Data($0) }, account: account)
        symmetricKeyCache[account] = key
        return key
    }
}
