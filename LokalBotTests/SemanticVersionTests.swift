import XCTest
@testable import BotinaV2

final class SemanticVersionTests: XCTestCase {
    func testParsesPlainVersion() {
        let v = SemanticVersion("1.2.3")
        XCTAssertEqual(v?.major, 1)
        XCTAssertEqual(v?.minor, 2)
        XCTAssertEqual(v?.patch, 3)
        XCTAssertEqual(v?.prerelease, [])
        XCTAssertEqual(v?.description, "1.2.3")
    }

    func testTolerantLeadingV() {
        XCTAssertEqual(SemanticVersion("v1.2.3"), SemanticVersion("1.2.3"))
        XCTAssertEqual(SemanticVersion("V1.2.3"), SemanticVersion("1.2.3"))
    }

    func testMissingComponentsDefaultToZero() {
        XCTAssertEqual(SemanticVersion("1"), SemanticVersion("1.0.0"))
        XCTAssertEqual(SemanticVersion("1.2"), SemanticVersion("1.2.0"))
    }

    func testIgnoresBuildMetadata() {
        XCTAssertEqual(SemanticVersion("1.2.3+sha.abc"), SemanticVersion("1.2.3"))
    }

    func testParsesPrerelease() {
        let v = SemanticVersion("1.0.0-beta.2")
        XCTAssertEqual(v?.prerelease, ["beta", "2"])
        XCTAssertEqual(v?.description, "1.0.0-beta.2")
    }

    func testRejectsMalformed() {
        XCTAssertNil(SemanticVersion(""))
        XCTAssertNil(SemanticVersion("1.0.0-"))                 // empty pre-release
        XCTAssertNil(SemanticVersion("1.0.0-alpha..2"))         // empty identifier
        XCTAssertNil(SemanticVersion("1.2.3.4"))                // too many components
        XCTAssertNil(SemanticVersion("a.b.c"))
    }

    func testNumericNotLexical() {
        // Catches the classic `0.1.10` vs `0.1.2` bug.
        XCTAssertTrue(SemanticVersion("0.1.2")! < SemanticVersion("0.1.10")!)
        XCTAssertTrue(SemanticVersion("0.9.0")! < SemanticVersion("0.10.0")!)
    }

    func testPrereleaseRanksBelowStable() {
        XCTAssertTrue(SemanticVersion("1.0.0-beta")! < SemanticVersion("1.0.0")!)
        XCTAssertFalse(SemanticVersion("1.0.0")! < SemanticVersion("1.0.0-beta")!)
    }

    func testPrereleaseIdentifierPrecedence() {
        // Numeric < alphanumeric.
        XCTAssertTrue(SemanticVersion("1.0.0-2")! < SemanticVersion("1.0.0-alpha")!)
        // Numeric identifiers compare numerically.
        XCTAssertTrue(SemanticVersion("1.0.0-2")! < SemanticVersion("1.0.0-10")!)
        // Fewer identifiers rank lower when shared ones are equal.
        XCTAssertTrue(SemanticVersion("1.0.0-beta")! < SemanticVersion("1.0.0-beta.1")!)
    }
}
