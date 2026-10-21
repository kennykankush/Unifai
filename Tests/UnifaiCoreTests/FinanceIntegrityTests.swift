import XCTest
@testable import UnifaiCore

@MainActor final class FinanceIntegrityTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-21T12:00:00Z")!
    private func reading(_ amount: Decimal, at date: Date) -> BalanceSnapshot {
        .init(balances: [Money(amount, "USD")], details: [.init("Purchased balance", Money(amount, "USD"))],
              observedAt: date, source: URL(string: "https://example.invalid")!, coverage: "Test")
    }
    private func store() throws -> (AppStore, UUID) {
        let repo = StateRepository(directory: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/test-data/\(UUID())"))
        let store = AppStore(repository: repo, vault: MemoryVault())
        try store.addAccount(integrationID: "deepseek", label: "Personal", billingScope: "", mode: .manual)
        return (store, store.state.accounts[0].id)
    }
    private func estimate(_ id: UUID, _ amount: Decimal, at date: Date) -> PaymentRecord {
        var record = PaymentRecord(accountID: id, description: "Detected credit", kind: .topUp, money: Money(amount, "USD"),
                                   paidAt: date, reference: "DETECTED-DEEPSEEK-\(date.timeIntervalSince1970)")
        record.estimated = true
        return record
    }
    func testTwoSeparateTopUpsAreBothDetectedEvenAfterFirstIsConfirmed() throws {
        let account = ConnectedAccount(integrationID: "deepseek", label: "Test", mode: .live)
        let firstTime = now.addingTimeInterval(-3600)
        var first = try XCTUnwrap(TopUpWatch.payments(old: reading(3.43, at: firstTime.addingTimeInterval(-60)),
            new: reading(13.43, at: firstTime), account: account, recorded: [], now: firstTime).first)
        XCTAssertEqual(first.detection?.before, Money(3.43, "USD"))
        for confirmed in [false, true] {
            first.estimated = confirmed ? nil : true
            let second = TopUpWatch.payments(old: reading(13.43, at: firstTime), new: reading(23.43, at: now),
                                             account: account, recorded: [first], now: now)
            XCTAssertEqual(second.count, 1)
            XCTAssertEqual(second.first?.money, Money(10, "USD"))
        }
    }
    func testOldManualPaymentDoesNotHideANewIncrease() {
        let account = ConnectedAccount(integrationID: "deepseek", label: "Test", mode: .live)
        let old = PaymentRecord(accountID: account.id, description: "Previous receipt", kind: .topUp, money: Money(50, "USD"),
                                paidAt: now.addingTimeInterval(-86400))
        XCTAssertEqual(TopUpWatch.payments(old: reading(3, at: now.addingTimeInterval(-3600)), new: reading(13, at: now),
                                           account: account, recorded: [old], now: now).count, 1)
    }
    func testReceiptWithinObservationIntervalSuppressesDuplicate() {
        let account = ConnectedAccount(integrationID: "deepseek", label: "Test", mode: .live)
        let receipt = PaymentRecord(accountID: account.id, description: "Receipt", kind: .topUp, money: Money(10, "USD"),
                                    paidAt: now.addingTimeInterval(-30), reference: "RECEIPT-1")
        XCTAssertTrue(TopUpWatch.payments(old: reading(3, at: now.addingTimeInterval(-60)), new: reading(12.8, at: now),
                                         account: account, recorded: [receipt], now: now).isEmpty)
    }
    func testReceiptReplacesOnlyOneOfSeveralNearbyEstimatesAndDuplicateImportIsSafe() throws {
        let (store, id) = try store()
        let first = estimate(id, 10, at: now.addingTimeInterval(-86400))
        let second = estimate(id, 20, at: now)
        try store.savePayment(first, now: now); try store.savePayment(second, now: now)
        let rows = try PaymentImport.parse("date,description,amount,currency,kind,account,reference\n2026-10-20,DeepSeek receipt,10,USD,top-up,deepseek,R-1")
        XCTAssertEqual(try store.importPayments(rows, now: now).replaced, 1)
        XCTAssertEqual(store.state.payments.count, 2)
        XCTAssertTrue(store.state.payments.contains { $0.id == first.id && !$0.autoRecorded })
        XCTAssertTrue(store.state.payments.contains { $0.id == second.id && $0.autoRecorded })
        let before = store.state
        XCTAssertEqual(try store.importPayments(rows, now: now).duplicates, 1)
        XCTAssertEqual(store.state, before)
    }
    func testAmbiguousReceiptLeavesWholeImportAndDiskUntouched() throws {
        let (store, id) = try store()
        try store.savePayment(estimate(id, 10, at: now.addingTimeInterval(-3600)), now: now)
        try store.savePayment(estimate(id, 10, at: now), now: now)
        let before = store.state
        let bytes = try Data(contentsOf: store.repository.file)
        let csv = "date,description,amount,currency,kind,account,reference\n2026-10-19,Earlier,1,USD,refund,deepseek,R-0\n2026-10-21,Ambiguous,10,USD,top-up,deepseek,R-1"
        XCTAssertThrowsError(try store.importPayments(PaymentImport.parse(csv), now: now))
        XCTAssertEqual(store.state, before)
        XCTAssertEqual(try Data(contentsOf: store.repository.file), bytes)
    }
    func testMultipleWalletsRequireLabelAndNeverReplaceAnotherWalletsEstimate() throws {
        let (store, personal) = try store()
        try store.addAccount(integrationID: "deepseek", label: "Work", billingScope: "", mode: .manual)
        let work = store.state.accounts[1].id
        try store.savePayment(estimate(personal, 10, at: now), now: now)
        try store.savePayment(estimate(work, 10, at: now), now: now)
        XCTAssertThrowsError(try store.importPayments(PaymentImport.parse("date,amount,currency,kind,account\n2026-10-21,10,USD,top-up,deepseek"), now: now))
        let csv = "date,amount,currency,kind,account,account_label,reference\n2026-10-21,10,USD,top-up,deepseek,Work,W-1"
        XCTAssertEqual(try store.importPayments(PaymentImport.parse(csv), now: now).replaced, 1)
        XCTAssertTrue(store.state.payments.first { $0.accountID == personal }!.autoRecorded)
        XCTAssertFalse(store.state.payments.first { $0.accountID == work }!.autoRecorded)
    }
    func testConfirmedDetectionRetainsEvidenceOnEditAndReceiptImport() throws {
        let (store, id) = try store()
        let account = store.state.accounts[0]
        let detected = try XCTUnwrap(TopUpWatch.payments(old: reading(3, at: now.addingTimeInterval(-60)),
            new: reading(13, at: now), account: account, recorded: [], now: now).first)
        try store.savePayment(detected, now: now)
        try store.confirmPayment(detected.id)
        XCTAssertEqual(store.state.payments[0].detection, detected.detection)
        XCTAssertFalse(store.state.payments[0].autoRecorded)
        var edited = PaymentRecord(id: detected.id, accountID: id, description: "DeepSeek receipt", kind: .topUp, money: Money(10, "USD"), paidAt: now)
        edited.reference = "R-1"
        try store.savePayment(edited, now: now)
        XCTAssertEqual(store.state.payments[0].detection, detected.detection)
    }
}
