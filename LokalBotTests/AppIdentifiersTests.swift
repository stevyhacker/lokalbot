import CryptoKit
import XCTest
@testable import LokalBot

final class AppIdentifiersTests: XCTestCase {
    @MainActor
    func testUITestRuntimeFlagDoesNotSelectDeterministicEncryptionKeyInProductionTarget() throws {
        let account = "production-key-regression-\(UUID().uuidString)"
        let deterministic = Data(SHA256.hash(data: Data("lokalbot-ui-test-\(account)".utf8)))
        let originalFlag = UserDefaults.standard.object(forKey: UITestRuntime.enabledKey)

        KeychainSecrets.delete(account: account)
        UserDefaults.standard.set(true, forKey: UITestRuntime.enabledKey)
        defer {
            if let originalFlag {
                UserDefaults.standard.set(originalFlag, forKey: UITestRuntime.enabledKey)
            } else {
                UserDefaults.standard.removeObject(forKey: UITestRuntime.enabledKey)
            }
            KeychainSecrets.delete(account: account)
        }

        let key = try KeychainSecrets.symmetricKey(account: account)
        let keyData = key.withUnsafeBytes { Data($0) }

        XCTAssertNotEqual(keyData, deterministic)
    }
}
