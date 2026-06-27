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
    static let enabledKey = "lokalbotv3.uiTest.enabled"
    static let storageRootKey = "lokalbotv3.uiTest.storageRoot"
    static let defaultsSuiteKey = "lokalbotv3.uiTest.defaultsSuite"
    private static let enabledArgument = "--lokalbot-ui-test"
    private static let storageRootArgument = "--lokalbot-storage-root"
    private static let defaultsSuiteArgument = "--lokalbot-defaults-suite"

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
    }

    static var defaultsSuiteName: String? {
        nonEmpty(ProcessInfo.processInfo.environment["LOKALBOT_DEFAULTS_SUITE"])
            ?? argumentValue(after: defaultsSuiteArgument)
            ?? nonEmpty(UserDefaults.standard.string(forKey: defaultsSuiteKey))
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
    static func string(account: String) -> String? {
        guard let data = data(account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func data(account: String) -> Data? {
        data(service: AppIdentifiers.bundleID, account: account)
    }

    static func setString(_ value: String, account: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            delete(account: account)
        } else {
            set(Data(trimmed.utf8), account: account)
        }
    }

    static func set(_ data: Data, account: String) {
        let query = baseQuery(service: AppIdentifiers.bundleID, account: account)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func delete(account: String) {
        SecItemDelete(baseQuery(service: AppIdentifiers.bundleID, account: account) as CFDictionary)
    }

    private static func data(service: String, account: String) -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var existing: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &existing) == errSecSuccess else {
            return nil
        }
        return existing as? Data
    }

    private static func baseQuery(service: String, account: String) -> [String: Any] {
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
        if let data = data(account: account) {
            let key = SymmetricKey(data: data)
            symmetricKeyCache[account] = key
            return key
        }
        let key = SymmetricKey(size: .bits256)
        set(key.withUnsafeBytes { Data($0) }, account: account)
        guard data(account: account) != nil else {
            throw NSError(domain: "LokalBot", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "Could not save encryption key (\(account))"])
        }
        symmetricKeyCache[account] = key
        return key
    }
}
