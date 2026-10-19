import XCTest
@testable import UnifaiCore

final class AgentReportTests: XCTestCase {
    private func sampleState(now: Date) -> (PersistentState, ConnectedAccount) {
        var state = PersistentState()
        var live = ConnectedAccount(integrationID: "openrouter", label: "Work", billingScope: "Org", mode: .live)
        live.snapshot = BalanceSnapshot(balances: [Money(70, "USD")], details: [.init("Reported credits purchased", Money(100, "USD"))],
                                        reportedConsumption: [Money(30, "USD")], observedAt: now.addingTimeInterval(-7200),
                                        source: URL(string: "https://openrouter.ai/api/v1/credits")!, coverage: "Totals")
        let manual = ConnectedAccount(integrationID: "chatgpt", label: "Personal", mode: .manual)
        state.accounts = [live, manual]
        state.payments = [
            .init(accountID: live.id, description: "Top-up", kind: .topUp, money: Money(100, "USD"), paidAt: now.addingTimeInterval(-86400 * 10)),
            .init(accountID: live.id, description: "Refund", kind: .refund, money: Money(5, "USD"), paidAt: now.addingTimeInterval(-86400)),
            .init(description: "DeepSeek", kind: .topUp, money: Money(50, "CNY"), paidAt: now.addingTimeInterval(-86400 * 40))
        ]
        state.subscriptions = [
            .init(accountID: manual.id, name: "Plus", price: Money(20, "USD"), cadence: .monthly, nextRenewal: now.addingTimeInterval(86400 * 3)),
            .init(name: "Yearly", price: Money(200, "USD"), cadence: .yearly, nextRenewal: now.addingTimeInterval(86400 * 90))
        ]
        return (state, live)
    }

    func testBalancesKeepAccountsAndCurrenciesAndFlagStaleness() throws {
        let now = Date()
        let (state, live) = sampleState(now: now)
        let balances = AgentReport.balances(state, now: now)
        XCTAssertEqual(balances.count, 2)
        XCTAssertEqual(balances[0].accountID, live.id.uuidString)
        XCTAssertEqual(balances[0].creditRemaining, [.init(Money(70, "USD"))])
        XCTAssertTrue(balances[0].stale)
        XCTAssertEqual(balances[1].mode, "manual")
        XCTAssertTrue(balances[1].creditRemaining.isEmpty)
        XCTAssertEqual(AgentReport.balances(state, provider: "OPENROUTER", now: now).count, 1)
        XCTAssertEqual(AgentReport.balances(state, provider: "work", now: now).count, 1)
    }

    func testSpendingSubtractsRefundsFiltersByDateAndLimits() {
        let now = Date()
        let (state, _) = sampleState(now: now)
        let all = AgentReport.spending(state)
        XCTAssertEqual(all.paidTotals, [.init(Money(50, "CNY")), .init(Money(95, "USD"))])
        XCTAssertEqual(all.payments.first?.signedAmount, "-5")
        let recent = AgentReport.spending(state, since: now.addingTimeInterval(-86400 * 20), limit: 1)
        XCTAssertEqual(recent.paidTotals, [.init(Money(95, "USD"))])
        XCTAssertEqual(recent.payments.count, 1)
    }

    func testRenewalsWindowAndOverviewNeverExposeCredentials() throws {
        let now = Date()
        let (state, _) = sampleState(now: now)
        let soon = AgentReport.renewals(state, withinDays: 30, now: now)
        XCTAssertEqual(soon.map(\.name), ["Plus"])
        XCTAssertEqual(soon.first?.daysUntil, 3)
        let overview = AgentReport.overview(state, now: now)
        XCTAssertEqual(overview.accountsNeedingAttention, ["OpenRouter account · Work"])
        let json = String(decoding: try AgentReport.encoder().encode(overview), as: UTF8.self)
        XCTAssertFalse(json.localizedCaseInsensitiveContains("credential"))
        XCTAssertTrue(json.contains("https://openrouter.ai/api/v1/credits"))
    }
}
