import XCTest
@testable import UnifaiCore

final class LedgerTests: XCTestCase {
    func testPaymentsDoNotIncludeConsumptionOrSchedulesAndKeepCurrencies() throws {
        let now = Date()
        let records: [PaymentRecord] = [
            .init(description: "Top-up", kind: .topUp, money: Money(100, "USD"), paidAt: now),
            .init(description: "Refund", kind: .refund, money: Money(10, "USD"), paidAt: now),
            .init(description: "CNY", kind: .topUp, money: Money(20, "CNY"), paidAt: now),
            .init(description: "Future", kind: .subscription, money: Money(999, "USD"), paidAt: now.addingTimeInterval(10))
        ]
        XCTAssertEqual(Ledger.paidTotals(records, through: now), [Money(20, "CNY"), Money(90, "USD")])
        XCTAssertThrowsError(try Ledger.validate(records[3], existing: [], now: now))
    }
    func testInvalidAmountsAndReferences() throws {
        for input in ["NaN", "-5", "1e5", "1,000", "1.2oops", "", "999999999999999999999999999999"] { XCTAssertNil(Money.parseAmount(input), input) }
        XCTAssertEqual(Money.parseAmount("0.12345678"), Decimal(string: "0.12345678"))
        let first = PaymentRecord(description: "One", kind: .topUp, money: Money(1, "USD"), paidAt: .distantPast, reference: " RECEIPT ")
        let duplicate = PaymentRecord(description: "Two", kind: .topUp, money: Money(1, "USD"), paidAt: .distantPast, reference: "receipt")
        XCTAssertThrowsError(try Ledger.validate(duplicate, existing: [first]))
        XCTAssertNoThrow(try Ledger.validate(first, existing: [first]))
    }
}
