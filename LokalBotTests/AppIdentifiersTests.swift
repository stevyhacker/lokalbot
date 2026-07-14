import CryptoKit
import XCTest
@testable import LokalBot

final class AppIdentifiersTests: XCTestCase {
    func testHostedUnitTestsUseProcessScopedLibraryAndDefaults() throws {
        guard UITestRuntime.isUnitTesting else {
            throw XCTSkip("requires the hosted LokalBot unit-test process")
        }
        let processID = String(ProcessInfo.processInfo.processIdentifier)
        let storageRoot = try XCTUnwrap(UITestRuntime.storageRoot)
        let defaultsSuite = try XCTUnwrap(UITestRuntime.defaultsSuiteName)

        XCTAssertTrue(storageRoot.hasSuffix("lokalbot-unit-tests-\(processID)"))
        XCTAssertEqual(defaultsSuite, "me.dotenv.LokalBot.unit-tests.\(processID)")
        XCTAssertNotEqual(
            URL(fileURLWithPath: storageRoot).standardizedFileURL,
            AppDirectories.applicationSupport.standardizedFileURL)
    }

    @MainActor
    func testUITestRuntimeFlagDoesNotSelectDeterministicEncryptionKeyInProductionTarget() throws {
        guard ProcessInfo.processInfo.environment["LOKALBOT_RUN_KEYCHAIN_TESTS"] == "1" else {
            throw XCTSkip("set LOKALBOT_RUN_KEYCHAIN_TESTS=1 to run the login-Keychain integration test")
        }
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
