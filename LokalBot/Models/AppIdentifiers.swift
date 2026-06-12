import Foundation
import Security

enum AppIdentifiers {
    static var bundleID: String {
        guard let bundleID = Bundle.main.bundleIdentifier else {
            preconditionFailure("LokalBot requires a bundle identifier.")
        }
        return bundleID
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
}
