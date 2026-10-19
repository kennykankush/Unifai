import XCTest
@testable import UnifaiCore

final class OpenAIConnectorTests: XCTestCase {
    func testCodexDecodesPlanWindowsAndCredits() throws {
        let account = Data(#"{"account":{"type":"chatgpt","email":"someone@example.com","planType":"plus"},"requiresOpenaiAuth":true}"#.utf8)
        let limits = Data(#"{"rateLimits":{"limitId":"codex","planType":"plus","primary":{"usedPercent":12,"windowDurationMins":300,"resetsAt":1792415448},"secondary":{"usedPercent":100,"windowDurationMins":10080,"resetsAt":1792874444},"credits":{"hasCredits":true,"unlimited":false,"balance":"231.0115480000"},"rateLimitReachedType":"rate_limit_reached"}}"#.utf8)
        let snapshot = try CodexClient.decode(account: account, limits: limits)
        XCTAssertEqual(snapshot.plan, "ChatGPT Plus")
        XCTAssertEqual(snapshot.allowances?.map(\.name), ["5-hour window", "Weekly window"])
        XCTAssertEqual(snapshot.allowances?.map(\.usedPercent), [12, 100])
        XCTAssertEqual(snapshot.allowances?.last?.resetsAt, Date(timeIntervalSince1970: 1792874444))
        XCTAssertEqual(snapshot.balances, [Money(Decimal(string: "231.011548")!, "CREDITS")])
        XCTAssertEqual(snapshot.limitReached, true)
        // The email is never kept.
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self).contains("example.com"))
    }

    func testCodexRejectsSignedOutAndAPIKeyAccounts() {
        let limits = Data(#"{"rateLimits":{}}"#.utf8)
        XCTAssertThrowsError(try CodexClient.decode(account: Data(#"{"account":null,"requiresOpenaiAuth":true}"#.utf8), limits: limits))
        XCTAssertThrowsError(try CodexClient.decode(account: Data(#"{"account":{"type":"apiKey"},"requiresOpenaiAuth":true}"#.utf8), limits: limits))
    }

    func testOpenAICostsSumsPerCurrencyAndKeepsTheLatestDay() throws {
        let now = Date()
        let today = Int(Calendar.current.startOfDay(for: now).timeIntervalSince1970)
        let body = """
        {"object":"page","data":[
          {"object":"bucket","start_time":\(today - 172800),"end_time":\(today - 86400),"results":[{"object":"organization.costs.result","amount":{"value":1.25,"currency":"usd"}}]},
          {"object":"bucket","start_time":\(today - 86400),"end_time":\(today),"results":[]},
          {"object":"bucket","start_time":\(today),"end_time":\(today + 86400),"results":[{"object":"organization.costs.result","amount":{"value":0.5,"currency":"usd"}}]}
        ],"has_more":false,"next_page":null}
        """
        let snapshot = try BalanceClient.decode(integrationID: "openai-api", data: Data(body.utf8), source: URL(string: "https://api.openai.com")!, now: now)
        XCTAssertTrue(snapshot.balances.isEmpty)
        XCTAssertEqual(snapshot.reportedConsumption, [Money(Decimal(string: "1.75")!, "USD")])
        XCTAssertEqual(snapshot.details.first?.value, Money(Decimal(string: "0.5")!, "USD"))
        XCTAssertEqual(snapshot.consumptionPeriod, "Last 30 days")
    }

    func testAllowanceNames() {
        XCTAssertEqual(AllowanceWindow.name(forMinutes: 300), "5-hour window")
        XCTAssertEqual(AllowanceWindow.name(forMinutes: 10080), "Weekly window")
        XCTAssertEqual(AllowanceWindow.name(forMinutes: 1440), "1-day window")
        XCTAssertEqual(AllowanceWindow.name(forMinutes: nil), "Usage window")
    }

    /// Opt-in: reads the real Codex sign-in on this Mac. Run with UNIFAI_TEST_CODEX=1.
    func testLiveCodexReadIfRequested() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["UNIFAI_TEST_CODEX"] == "1", "Set UNIFAI_TEST_CODEX=1 to read the local Codex account.")
        let snapshot = try await CodexClient().fetch()
        XCTAssertNotNil(snapshot.plan)
        XCTAssertFalse(snapshot.allowances?.isEmpty ?? true)
        print("Codex live read: \(snapshot.plan ?? "-"), windows \(snapshot.allowances?.map { "\($0.name) \($0.usedPercent)%" } ?? []), credits \(snapshot.balances.map(\.plainText))")
    }
}

private extension Money { var plainText: String { "\(amount) \(currency)" } }

final class OpenAIAuthorizationTests: XCTestCase {
    func testOpenAIRefusalExplainsAdminKeyWhileOthersStayTyped() async throws {
        let session = StubProtocol.session(); defer { session.invalidateAndCancel() }
        StubProtocol.handler = { request in
            XCTAssertTrue(request.url?.absoluteString.hasPrefix("https://api.openai.com/v1/organization/costs?start_time=") == true)
            XCTAssertNil(request.httpBody)
            return (401, [:], Data("fixture-secret-response".utf8))
        }
        do { _ = try await BalanceClient(session: session).fetch(integrationID: "openai-api", credential: "fixture-key"); XCTFail("Expected rejection") }
        catch {
            XCTAssertTrue(error.localizedDescription.contains("Admin key"))
            XCTAssertFalse(error.localizedDescription.contains("fixture-secret"))
        }
    }
}

final class ClaudeCodeConnectorTests: XCTestCase {
    func testClaudePlanDecodesWithoutKeepingIdentity() throws {
        let data = Data(#"{"loggedIn":true,"authMethod":"claude.ai","email":"someone@example.com","orgId":"org-1","orgName":"Example","subscriptionType":"max"}"#.utf8)
        let snapshot = try ClaudeCodeClient.decode(data)
        XCTAssertEqual(snapshot.plan, "Claude Max")
        XCTAssertTrue(snapshot.balances.isEmpty)
        XCTAssertNil(snapshot.allowances)
        let encoded = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        XCTAssertFalse(encoded.contains("example.com")); XCTAssertFalse(encoded.contains("org-1"))
    }
    func testClaudeSignedOutOrAPIKeyIsExplained() {
        XCTAssertThrowsError(try ClaudeCodeClient.decode(Data(#"{"loggedIn":false}"#.utf8)))
        XCTAssertThrowsError(try ClaudeCodeClient.decode(Data(#"{"loggedIn":true,"authMethod":"api-key"}"#.utf8)))
        XCTAssertThrowsError(try ClaudeCodeClient.decode(Data("not json".utf8)))
    }
    /// Opt-in: reads `claude auth status` on this Mac. Run with UNIFAI_TEST_CLAUDE=1.
    func testLiveClaudeReadIfRequested() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["UNIFAI_TEST_CLAUDE"] == "1", "Set UNIFAI_TEST_CLAUDE=1 to read the local Claude Code status.")
        let snapshot = try await ClaudeCodeClient().fetch()
        print("Claude live read: \(snapshot.plan ?? "-")")
        XCTAssertNotNil(snapshot.plan)
    }
}
