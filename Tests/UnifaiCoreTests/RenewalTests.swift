import XCTest
@testable import UnifaiCore

@MainActor
final class RenewalTests: XCTestCase {
    private func store() -> AppStore {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return AppStore(repository: StateRepository(directory: root.appendingPathComponent(".build/test-data/\(UUID().uuidString)")), vault: MemoryVault())
    }
    private func day(_ text: String) -> Date {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f.date(from: text)!.addingTimeInterval(12 * 3600)
    }

    func testDetectsMonthlyPlanFromMessyHistoryAndFlagsUpgradePrice() throws {
        let store = store()
        try store.addAccount(integrationID: "claude-subscription", label: "Personal", billingScope: "", mode: .manual)
        let id = store.state.accounts[0].id
        let history: [(String, Decimal, String)] = [("2026-04-18", 149.99, "Claude Max 5x"), ("2026-06-11", 149.99, "Claude Max 5x"), ("2026-07-11", 149.99, "Claude Max 5x"),
                                                    ("2026-08-11", 120.16, "Claude Max 5x (upgrade)"), ("2026-08-11", 30, "Claude Pro"), ("2026-09-20", 149.99, "Claude Max 5x"),
                                                    ("2026-10-06", 230.09, "Claude Max 20x (upgrade)")]
        for (index, entry) in history.enumerated() {
            try store.savePayment(.init(accountID: id, description: entry.2, kind: .subscription, money: Money(entry.1, "SGD"), paidAt: day(entry.0), reference: "R\(index)"), now: day("2026-10-19"))
        }
        let suggestions = RenewalDetector.suggestions(store.state, now: day("2026-10-19"))
        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions[0].name, "Claude Max 20x")
        XCTAssertEqual(suggestions[0].cadence, .monthly)
        XCTAssertEqual(Calendar.current.component(.day, from: suggestions[0].nextRenewal), 6)
        XCTAssertEqual(Calendar.current.component(.month, from: suggestions[0].nextRenewal), 11)
        XCTAssertTrue(suggestions[0].estimated)

        try store.dismissSuggestion(suggestions[0].id)
        XCTAssertTrue(RenewalDetector.suggestions(store.state, now: day("2026-10-19")).isEmpty)
    }

    func testNoSuggestionForLapsedPlansOrWalletsWithSchedules() throws {
        let store = store()
        try store.addAccount(integrationID: "chatgpt", label: "Personal", billingScope: "", mode: .manual)
        let id = store.state.accounts[0].id
        for (index, date) in ["2025-01-05", "2025-02-05", "2025-03-05"].enumerated() {
            try store.savePayment(.init(accountID: id, description: "ChatGPT Plus", kind: .subscription, money: Money(20, "USD"), paidAt: day(date), reference: "C\(index)"))
        }
        XCTAssertTrue(RenewalDetector.suggestions(store.state, now: day("2026-10-19")).isEmpty, "Lapsed for over a year")
        XCTAssertEqual(RenewalDetector.suggestions(store.state, now: day("2025-03-20")).count, 1)
        try store.saveSubscription(.init(accountID: id, name: "ChatGPT Plus", price: Money(20, "USD"), cadence: .monthly, nextRenewal: day("2025-04-05")))
        XCTAssertTrue(RenewalDetector.suggestions(store.state, now: day("2025-03-20")).isEmpty)
    }

    func testRecordsDueRenewalsOnceAndAdvancesWithoutInventingHistory() throws {
        let store = store()
        let created = day("2026-09-01")
        try store.saveSubscription(.init(name: "Claude Max 20x", price: Money(299.98, "SGD"), cadence: .monthly, nextRenewal: day("2026-09-06"), createdAt: created))
        try store.saveSubscription(.init(name: "Old plan", price: Money(10, "USD"), cadence: .monthly, nextRenewal: day("2026-08-01"), createdAt: created))
        try store.saveSubscription(.init(name: "Manual plan", price: Money(5, "USD"), cadence: .monthly, nextRenewal: day("2026-09-10"), autoRecord: false, createdAt: created))

        let posted = store.recordDueRenewals(now: day("2026-10-19"))
        XCTAssertEqual(posted.map(\.paidAt), [day("2026-09-06"), day("2026-10-06")])
        XCTAssertTrue(posted.allSatisfy(\.autoRecorded))
        XCTAssertEqual(Ledger.paidTotals(store.state.payments), [Money(599.96, "SGD")])
        XCTAssertEqual(store.state.subscriptions[0].nextRenewal, day("2026-11-06"))
        XCTAssertEqual(store.state.subscriptions[1].nextRenewal, day("2026-08-01"), "Dates before the schedule existed are left for the user")
        XCTAssertEqual(store.state.subscriptions[2].nextRenewal, day("2026-09-10"), "Auto-record off")
        XCTAssertTrue(store.recordDueRenewals(now: day("2026-10-19")).isEmpty, "Idempotent")

        try store.confirmPayment(posted[0].id)
        XCTAssertFalse(store.state.payments.first { $0.id == posted[0].id }!.autoRecorded)
    }

    func testImportedReceiptReplacesTheAutomaticEntry() throws {
        let store = store()
        try store.addAccount(integrationID: "claude-subscription", label: "Personal", billingScope: "", mode: .manual)
        let id = store.state.accounts[0].id
        try store.saveSubscription(.init(accountID: id, name: "Claude Max 20x", price: Money(299.98, "SGD"), cadence: .monthly, nextRenewal: day("2026-10-06"), createdAt: day("2026-10-01")))
        _ = store.recordDueRenewals(now: day("2026-10-19"))
        XCTAssertEqual(store.state.payments.count, 1)
        let summary = try store.importPayments(try PaymentImport.parse("date,description,amount,currency,kind,account,reference\n2026-10-07,Claude Max 20x,327.00,SGD,subscription,claude-subscription,REAL-1"), now: day("2026-10-19"))
        XCTAssertEqual(summary.replaced, 1)
        XCTAssertEqual(store.state.payments.count, 1)
        XCTAssertEqual(store.state.payments[0].reference, "REAL-1")
        XCTAssertFalse(store.state.payments[0].autoRecorded)
    }
}
