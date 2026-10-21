import XCTest
@testable import UnifaiCore

final class AgentToolsTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-21T12:00:00Z")!
    private func fixture() -> PersistentState {
        var state = PersistentState()
        var account = ConnectedAccount(integrationID: "deepseek", label: "Personal", mode: .live)
        account.snapshot = .init(balances: [Money(13, "USD")], observedAt: now, source: URL(string: "https://example.invalid")!, coverage: "Current balance only")
        state.accounts = [account]
        var estimated = PaymentRecord(accountID: account.id, description: "Detected", kind: .topUp, money: Money(10, "USD"), paidAt: now)
        estimated.estimated = true
        state.payments = [estimated, .init(accountID: account.id, description: "Paid", kind: .subscription, money: Money(20, "USD"), paidAt: now)]
        state.subscriptions = [.init(accountID: account.id, name: "Monthly", price: Money(30, "USD"), cadence: .monthly,
                                     nextRenewal: now.addingTimeInterval(86400))]
        state.displayCurrency = "USD"
        return state
    }
    private func json(_ name: String, _ arguments: [String: Any] = [:], state: PersistentState) throws -> [String: Any] {
        let data = try AgentTools.call(name, arguments: arguments, state: state, rates: nil, now: now)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    func testEveryRichToolIsReadOnlyAndReturnsStructuredDataWithoutMutatingInput() throws {
        let state = fixture()
        let initial = try JSONEncoder().encode(state)
        for definition in AgentTools.definitions {
            let name = definition["name"] as! String
            var arguments: [String: Any] = [:]
            if name == "get_account_details" { arguments["account_id"] = state.accounts[0].id.uuidString }
            if name == "get_payment" { arguments["payment_id"] = state.payments[0].id.uuidString }
            XCTAssertFalse(try json(name, arguments, state: state).isEmpty)
            XCTAssertEqual((definition["annotations"] as? [String: Bool])?["readOnlyHint"], true)
        }
        XCTAssertEqual(try JSONDecoder().decode(PersistentState.self, from: initial), state)
    }
    func testBreakdownPaginationPreservesTotalsAndDateBoundaryIncludesWholeDay() throws {
        let state = fixture()
        let first = try json("get_spending_breakdown", ["since": "2026-10-21", "through": "2026-10-21", "limit": 1], state: state)
        XCTAssertEqual(first["totalEntries"] as? Int, 2)
        XCTAssertEqual(first["hasMore"] as? Bool, true)
        let report = try XCTUnwrap(first["breakdown"] as? [String: Any])
        XCTAssertEqual((report["total"] as? [String: Any])?["amount"] as? Int, 30)
        let second = try json("get_spending_breakdown", ["offset": 1, "limit": 1], state: state)
        XCTAssertEqual(second["hasMore"] as? Bool, false)
    }
    func testPaymentEvidenceAndReviewAreExplicit() throws {
        var state = fixture()
        state.payments[0].detection = .init(before: Money(3, "USD"), after: Money(13, "USD"),
                                           observedFrom: now.addingTimeInterval(-60), observedThrough: now, lowerBound: true)
        let payment = try json("get_payment", ["payment_id": state.payments[0].id.uuidString], state: state)
        XCTAssertEqual(payment["status"] as? String, "estimate")
        XCTAssertNotNil(payment["detection"])
        let review = try json("get_unconfirmed_payments", state: state)
        XCTAssertEqual(review["totalEntries"] as? Int, 1)
        XCTAssertTrue((review["receiptRequest"] as? String)?.contains("kind top-up") == true)
        XCTAssertTrue((review["receiptRequest"] as? String)?.contains("account_label=Personal") == true)
    }
    func testMalformedArgumentsCannotProducePlausibleTotals() throws {
        let state = fixture()
        for args: [String: Any] in [
            ["since": "2026-02-30"], ["since": "2027-01-01"], ["limit": true], ["limit": 2.5], ["limit": -1],
            ["offset": 100001], ["currency": "CREDITS"], ["account_id": "unknown"], ["period": "week"],
            ["include_accruing": "yes"], ["extra": 1]
        ] {
            XCTAssertThrowsError(try AgentTools.call("get_spending_breakdown", arguments: args, state: state, rates: nil, now: now))
        }
        XCTAssertThrowsError(try json("get_payment", state: state))
        XCTAssertThrowsError(try json("get_account_details", ["account_id": UUID().uuidString], state: state))
    }
    func testOutlookIncludesRepeatedSchedulesWithoutCountingPaymentsOrOverduePlans() {
        var state = fixture()
        state.subscriptions.append(.init(name: "Overdue", price: Money(500, "USD"), cadence: .monthly, nextRenewal: now.addingTimeInterval(-86400)))
        let outlook = AgentTools.outlook(state, rates: nil, currency: "USD", days: 65, now: now)
        XCTAssertEqual(outlook.charges.count, 3)
        XCTAssertEqual(outlook.convertedTotal, Money(90, "USD"))
        XCTAssertEqual(outlook.overdue.count, 1)
    }
    func testStaleAndFailedWalletsAreNeverRecommendedAsAvailable() {
        var state = fixture()
        state.accounts[0].snapshot?.observedAt = now.addingTimeInterval(-7200)
        var other = ConnectedAccount(integrationID: "openrouter", label: "Work", mode: .live)
        other.snapshot = .init(balances: [Money(100, "USD")], observedAt: now, source: URL(string: "https://example.invalid")!, coverage: "Test")
        other.lastError = "Permission denied"
        state.accounts.append(other)
        state.accounts.append(ConnectedAccount(integrationID: "claude-subscription", label: "Plan only", mode: .manual))
        let report = AgentReport.headroom(state, now: now)
        XCTAssertFalse(report.ranked.contains(where: \.usableNow))
        XCTAssertTrue(report.recommendation.contains("No fresh reading"))
        XCTAssertEqual(report.unmeasuredAccounts.count, 1)
        XCTAssertEqual(AgentTools.health(state, rates: nil, now: now).accounts.map(\.status), ["stale", "failed", "manual"])
    }
}
