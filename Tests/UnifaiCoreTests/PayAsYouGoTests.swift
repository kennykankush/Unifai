import XCTest
@testable import UnifaiCore

@MainActor
final class PayAsYouGoTests: XCTestCase {
    private func day(_ text: String) -> Date { RateTable.dayFormatter.date(from: text)!.addingTimeInterval(12 * 3600) }
    private func store() -> AppStore {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return AppStore(repository: StateRepository(directory: root.appendingPathComponent(".build/test-data/\(UUID().uuidString)")), vault: MemoryVault(),
                        balances: { id, _, now in
                            if id == "azure-subscription" {
                                return BalanceSnapshot(balances: [], reportedConsumption: [Money(Decimal(string: "17.15")!, "USD")], observedAt: now,
                                                       source: URL(string: "https://example.invalid")!, coverage: "Synthetic", consumptionPeriod: "This month")
                            }
                            return BalanceSnapshot(balances: [Money(9, "USD")], reportedConsumption: [Money(1, "USD")], observedAt: now,
                                                   source: URL(string: "https://example.invalid")!, coverage: "Synthetic")
                        })
    }

    func testBillingModels() {
        XCTAssertEqual(Catalogue.integration("azure-subscription")?.billing, .payAsYouGo)
        XCTAssertEqual(Catalogue.integration("openrouter")?.billing, .prepaid)
        XCTAssertEqual(Catalogue.integration("codex")?.billing, .allowance)
        XCTAssertEqual(Catalogue.integration("cursor")?.billing, .subscription)
    }

    func testAccruingUsageCountsTowardsThisMonthButNotPaid() async throws {
        let store = store()
        try store.addAccount(integrationID: "azure-subscription", label: "Personal", billingScope: "Azure", mode: .live)
        try store.addAccount(integrationID: "openrouter", label: "Dev", billingScope: "dev", mode: .live, credential: "k")
        let now = Date()
        for account in store.state.accounts { await store.refreshAccount(account.id, now: now) }
        XCTAssertEqual(store.state.accruingThisMonth(now: now).map(\.amount), [Money(Decimal(string: "17.15")!, "USD")], "Prepaid consumption is not an accrual")
        XCTAssertEqual(store.state.monthToDateSpend(in: "USD", rates: nil, now: now, includeAccruing: true).spent, Money(Decimal(string: "17.15")!, "USD"))
        XCTAssertEqual(store.state.monthToDateSpend(in: "USD", rates: nil, now: now).spent, Money(0, "USD"))
        XCTAssertTrue(Ledger.paidTotals(store.state.payments).isEmpty)
    }

    func testMonthEndRecordsTheLastReadingOnceAndAnInvoiceReplacesIt() async throws {
        let store = store()
        try store.addAccount(integrationID: "azure-subscription", label: "Personal", billingScope: "Azure", mode: .live)
        let id = store.state.accounts[0].id
        await store.refreshAccount(id, now: day("2026-10-30"))
        XCTAssertTrue(store.closePayAsYouGoPeriods(now: day("2026-10-31")).isEmpty, "Same month: nothing to close")
        let closed = store.closePayAsYouGoPeriods(now: day("2026-11-02"))
        XCTAssertEqual(closed.count, 1)
        XCTAssertEqual(closed[0].description, "Azure subscriptions usage, October 2026")
        XCTAssertEqual(closed[0].kind, .usageCharge)
        XCTAssertTrue(closed[0].autoRecorded)
        XCTAssertTrue(store.closePayAsYouGoPeriods(now: day("2026-11-03")).isEmpty, "Once per month")
        XCTAssertTrue(store.state.accruingThisMonth(now: day("2026-11-02")).isEmpty, "Last month's reading is no longer accruing")

        let invoice = "date,description,amount,currency,kind,account,reference\n2026-11-03,Azure invoice October,18.02,USD,usage,azure-subscription,INV-10"
        let summary = try store.importPayments(try PaymentImport.parse(invoice), now: day("2026-11-04"))
        XCTAssertEqual(summary.replaced, 1)
        XCTAssertEqual(store.state.payments.map(\.reference), ["INV-10"])
    }

    func testRefreshInANewMonthClosesThePreviousMonthFirst() async throws {
        let store = store()
        try store.addAccount(integrationID: "azure-subscription", label: "Personal", billingScope: "Azure", mode: .live)
        let id = store.state.accounts[0].id
        await store.refreshAccount(id, now: day("2026-10-29"))
        await store.refreshAccount(id, now: day("2026-11-01"))
        XCTAssertEqual(store.state.payments.count, 1)
        XCTAssertEqual(store.state.payments[0].money, Money(Decimal(string: "17.15")!, "USD"))
        XCTAssertEqual(Calendar.current.component(.month, from: store.state.payments[0].paidAt), 10)
    }
}
