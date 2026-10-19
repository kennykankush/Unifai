import XCTest
@testable import UnifaiCore

@MainActor
final class ExchangeRateTests: XCTestCase {
    private let csv = """
    KEY,FREQ,CURRENCY,CURRENCY_DENOM,EXR_TYPE,EXR_SUFFIX,TIME_PERIOD,OBS_VALUE
    EXR.D.USD.EUR.SP00.A,D,USD,EUR,SP00,A,2026-10-16,1.0800
    EXR.D.SGD.EUR.SP00.A,D,SGD,EUR,SP00,A,2026-10-16,1.4040
    EXR.D.USD.EUR.SP00.A,D,USD,EUR,SP00,A,2025-03-05,1.0000
    EXR.D.SGD.EUR.SP00.A,D,SGD,EUR,SP00,A,2025-03-05,1.4500
    """
    private func day(_ text: String) -> Date { RateTable.dayFormatter.date(from: text)!.addingTimeInterval(12 * 3600) }

    func testConvertsThroughEuroOnThePaymentDate() throws {
        let table = try ExchangeRates.parse(csv, currencies: ["SGD", "USD"])
        XCTAssertEqual(table.convert(Money(Decimal(string: "21.80")!, "USD"), to: "SGD", on: day("2025-03-05")), Money(Decimal(string: "31.61")!, "SGD"))
        XCTAssertEqual(table.convert(Money(108, "USD"), to: "SGD", on: day("2026-10-16")), Money(Decimal(string: "140.4")!, "SGD"))
        XCTAssertEqual(table.convert(Money(30, "SGD"), to: "SGD", on: day("2026-10-16")), Money(30, "SGD"))
    }

    func testWeekendUsesTheLatestEarlierRateAndUnknownCurrenciesStaySeparate() throws {
        let table = try ExchangeRates.parse(csv, currencies: ["SGD", "USD"])
        // Saturday and Sunday after a Friday publication.
        XCTAssertEqual(table.perEuro("SGD", on: day("2026-10-18")), 1.4040)
        XCTAssertNil(table.convert(Money(5, "CREDITS"), to: "SGD", on: day("2026-10-16")))
        XCTAssertThrowsError(try ExchangeRates.parse("nothing,useful\n", currencies: ["SGD"]))
    }

    func testStoreCombinesCurrenciesWithoutChangingRecordedPayments() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let table = try ExchangeRates.parse(csv, currencies: ["SGD", "USD"])
        let store = AppStore(repository: StateRepository(directory: root.appendingPathComponent(".build/test-data/\(UUID().uuidString)")), vault: MemoryVault(),
                             rates: { _, _, now in RateTable(rates: table.rates, fetchedAt: now, currencies: table.currencies) })
        try store.savePayment(.init(description: "Plus", kind: .subscription, money: Money(Decimal(string: "21.80")!, "USD"), paidAt: day("2025-03-05"), reference: "A"))
        try store.savePayment(.init(description: "Plus", kind: .subscription, money: Money(30, "SGD"), paidAt: day("2026-10-16"), reference: "B"))
        await store.setDisplayCurrency("SGD")
        let rates = try XCTUnwrap(store.rates)
        let combined = store.state.payments(in: "SGD", rates: rates)
        XCTAssertEqual(Ledger.paidTotals(combined.converted), [Money(Decimal(string: "61.61")!, "SGD")])
        XCTAssertTrue(combined.unconverted.isEmpty)
        XCTAssertEqual(Ledger.paidTotals(store.state.payments), [Money(30, "SGD"), Money(Decimal(string: "21.8")!, "USD")], "Originals unchanged")
        XCTAssertNotNil(RateStore(directory: store.repository.directory).load(), "Rates cached for the MCP server and next launch")
    }

    /// Opt-in: one live request to the ECB data API. Run with UNIFAI_TEST_ECB=1.
    func testLiveECBIfRequested() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["UNIFAI_TEST_ECB"] == "1", "Set UNIFAI_TEST_ECB=1 for a live ECB request.")
        let table = try await ExchangeRates.fetch(currencies: ["USD", "SGD"], since: Date().addingTimeInterval(-30 * 86400))
        let converted = try XCTUnwrap(table.convert(Money(100, "USD"), to: "SGD", on: Date()))
        print("ECB live: 100 USD = \(converted.amount) SGD across \(table.rates.count) days")
        XCTAssertGreaterThan(converted.amount, 100)
    }
}
