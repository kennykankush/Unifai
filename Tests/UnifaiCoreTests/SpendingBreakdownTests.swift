import XCTest
@testable import UnifaiCore

final class SpendingBreakdownTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-21T12:00:00Z")!
    private func sample() -> (PersistentState, RateTable) {
        var state = PersistentState()
        var azure = ConnectedAccount(integrationID: "azure-subscription", label: "Work", mode: .live)
        azure.snapshot = BalanceSnapshot(balances: [], reportedConsumption: [Money(10, "USD")], observedAt: now,
                                         source: URL(string: "https://example.invalid")!, coverage: "Synthetic", consumptionPeriod: "This month")
        state.accounts = [azure]
        var estimate = PaymentRecord(description: "Top-up", kind: .topUp, money: Money(10, "USD"), paidAt: now)
        estimate.estimated = true
        let automatic = PaymentRecord(description: "Renewal", kind: .subscription, money: Money(20, "SGD"), paidAt: now, scheduleID: UUID())
        state.payments = [.init(description: "Paid", kind: .subscription, money: Money(100, "SGD"), paidAt: now),
                          .init(description: "Refund", kind: .refund, money: Money(5, "SGD"), paidAt: now), estimate, automatic]
        state.subscriptions = [.init(name: "Future", price: Money(300, "SGD"), cadence: .monthly, nextRenewal: now.addingTimeInterval(86400))]
        state.monthlyBudget = Money(200, "SGD")
        return (state, RateTable(rates: ["2026-10-20": ["USD": 1, "SGD": 1.3]], fetchedAt: now, currencies: ["USD", "SGD"]))
    }
    func testBreakdownAndBudgetShareArithmeticWithRefundsEstimatesAndAccrual() {
        let (state, rates) = sample()
        let start = Calendar.current.dateInterval(of: .month, for: now)!.start
        let result = state.spendingBreakdown(in: "SGD", rates: rates, since: start, now: now)
        XCTAssertEqual(result.confirmedPayments, Money(95, "SGD"))
        XCTAssertEqual(result.estimatedPayments, Money(13, "SGD"))
        XCTAssertEqual(result.automaticPayments, Money(20, "SGD"))
        XCTAssertEqual(result.accruingUsage, Money(13, "SGD"))
        XCTAssertEqual(result.total, Money(141, "SGD"))
        XCTAssertEqual(result.entries.count, 5)
        XCTAssertEqual(state.monthToDateSpend(in: "SGD", rates: rates, now: now, includeAccruing: true).spent, result.total)
        XCTAssertEqual(AgentReport.overview(state, now: now, rates: rates).budget?.spentIncludingAccruing, .init(result.total))
        XCTAssertTrue(result.entries.filter { $0.original.currency == "USD" }.allSatisfy { $0.conversion?.contains("2026-10-20") == true })
    }
    func testUnknownCurrenciesAreVisibleAndNeverSilentlyIncluded() {
        var (state, rates) = sample()
        state.payments.append(.init(description: "No rate", kind: .topUp, money: Money(50, "JPY"), paidAt: now))
        let result = state.spendingBreakdown(in: "SGD", rates: rates, now: now)
        XCTAssertFalse(result.complete)
        XCTAssertEqual(result.total.amount, 141)
        XCTAssertEqual(result.entries.filter { $0.converted == nil }.map(\.original), [Money(50, "JPY")])
    }
    func testPartialOrHistoricalRangeDoesNotMisallocateWholeMonthAccrual() {
        let (state, rates) = sample()
        let partial = state.spendingBreakdown(in: "SGD", rates: rates, since: now.addingTimeInterval(-86400), now: now)
        XCTAssertEqual(partial.accruingUsage.amount, 0)
        XCTAssertTrue(partial.notes.contains { $0.contains("cannot be allocated") })
        let historical = state.spendingBreakdown(in: "SGD", rates: rates, through: now.addingTimeInterval(-86400), now: now)
        XCTAssertTrue(historical.entries.isEmpty)
    }
    func testAccountFilterAndStaleAccrualRemainExplicit() {
        var (state, rates) = sample()
        state.accounts[0].snapshot?.observedAt = now.addingTimeInterval(-7200)
        state.accounts[0].lastError = "Refresh failed"
        let result = state.spendingBreakdown(in: "SGD", rates: rates, accountID: state.accounts[0].id, now: now)
        XCTAssertEqual(result.total.amount, 13)
        XCTAssertTrue(result.entries[0].stale)
        XCTAssertEqual(result.entries[0].lastError, "Refresh failed")
    }
}
