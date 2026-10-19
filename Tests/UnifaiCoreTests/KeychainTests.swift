import XCTest
@testable import UnifaiCore

final class KeychainTests: XCTestCase {
    func testSyntheticKeychainRoundTripAndPerAccountIsolation() throws {
        guard ProcessInfo.processInfo.environment["UNIFAI_TEST_KEYCHAIN"] == "1" else {
            throw XCTSkip("Opt in with UNIFAI_TEST_KEYCHAIN=1. Only creates and removes synthetic items in a unique Unifai test service.")
        }
        let vault = KeychainVault(service: "dev.unifai.synthetic-test.\(UUID().uuidString)")
        let a = UUID(), b = UUID()
        defer { try? vault.delete(accountID: a); try? vault.delete(accountID: b) }
        XCTAssertNil(try vault.read(accountID: a))
        try vault.write("synthetic-a", accountID: a); try vault.write("synthetic-b", accountID: b)
        XCTAssertEqual(try vault.read(accountID: a), "synthetic-a"); XCTAssertEqual(try vault.read(accountID: b), "synthetic-b")
        try vault.write("synthetic-a-replaced", accountID: a)
        XCTAssertEqual(try vault.read(accountID: a), "synthetic-a-replaced")
        try vault.delete(accountID: a)
        XCTAssertNil(try vault.read(accountID: a)); XCTAssertEqual(try vault.read(accountID: b), "synthetic-b")
    }
}
