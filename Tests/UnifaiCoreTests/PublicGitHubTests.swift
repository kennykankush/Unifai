import XCTest
@testable import UnifaiCore

final class PublicGitHubTests: XCTestCase {
    func testOneAnonymousPublicReleaseRequest() async throws {
        guard ProcessInfo.processInfo.environment["UNIFAI_TEST_PUBLIC_GITHUB"] == "1" else {
            throw XCTSkip("Opt in with UNIFAI_TEST_PUBLIC_GITHUB=1 for one anonymous public GET to swiftlang/swift.")
        }
        let result = try await GitHubClient().fetch(.init(slug: "swiftlang/swift"))
        let items = try XCTUnwrap(result.releases)
        XCTAssertFalse(items.isEmpty)
        XCTAssertLessThanOrEqual(items.count, 50)
        XCTAssertTrue(items.allSatisfy { $0.url.host == "github.com" && $0.url.path.hasPrefix("/swiftlang/swift/releases/") })
        XCTAssertGreaterThan(result.retryAfter, Date())
        print("Public GitHub smoke: \(items.count) releases, one anonymous GET, no credential or paid endpoint.")
    }
}
