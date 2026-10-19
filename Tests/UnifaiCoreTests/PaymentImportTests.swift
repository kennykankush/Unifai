import XCTest
@testable import UnifaiCore

@MainActor
final class PaymentImportTests: XCTestCase {
    private func store() -> AppStore {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return AppStore(repository: StateRepository(directory: root.appendingPathComponent(".build/test-data/\(UUID().uuidString)")), vault: MemoryVault())
    }

    private let csv = """
    date,description,amount,currency,kind,account,account_label,reference
    2025-01-29,"Claude Pro, monthly",30.00,SGD,subscription,claude-subscription,Personal,2906-2287
    2026-10-17,Claude API credits,25.00,USD,top-up,Claude API / Console,,2140-0407-7235
    2026-10-17,Refund,5.00,USD,refund,claude-api,,2140-0407-9999
    """

    func testParsesQuotedFieldsKindsAndServices() throws {
        let rows = try PaymentImport.parse(csv)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].description, "Claude Pro, monthly")
        XCTAssertEqual(rows[0].money, Money(30, "SGD"))
        XCTAssertEqual(rows[0].kind, .subscription)
        XCTAssertEqual(rows[1].integrationID, "claude-api")
        XCTAssertEqual(rows[1].accountLabel, "Personal")
        XCTAssertEqual(rows[2].kind, .refund)
        XCTAssertEqual(Calendar.current.component(.day, from: rows[0].paidAt), 29)
    }

    func testRejectsBadRowsWithLineNumbers() {
        for (body, fragment) in [("date,amount,currency\n2025-13-40,1,USD", "Line 2"), ("date,amount,currency\n2025-01-01,-5,USD", "positive"),
                                 ("date,amount,currency\n2025-01-01,5,XYZ", "XYZ"), ("date,amount,currency,account\n2025-01-01,5,USD,Nope", "Nope"),
                                 ("amount,currency\n5,USD", "header")] {
            XCTAssertThrowsError(try PaymentImport.parse(body)) { XCTAssertTrue($0.localizedDescription.contains(fragment), "\($0.localizedDescription)") }
        }
    }

    func testImportCreatesWalletsSkipsDuplicatesAndKeepsCurrencies() throws {
        let store = store()
        let first = try store.importPayments(try PaymentImport.parse(csv))
        XCTAssertEqual(first.imported, 3)
        XCTAssertEqual(first.createdAccounts.count, 2)
        XCTAssertEqual(store.state.accounts.map(\.mode), [.manual, .manual])
        XCTAssertEqual(Ledger.paidTotals(store.state.payments), [Money(30, "SGD"), Money(20, "USD")])
        let again = try store.importPayments(try PaymentImport.parse(csv))
        XCTAssertEqual(again.imported, 0); XCTAssertEqual(again.duplicates, 3)
        XCTAssertEqual(store.state.payments.count, 3)
    }

    func testImportUsesExistingWalletAndIsAllOrNothing() throws {
        let store = store()
        try store.addAccount(integrationID: "claude-api", label: "Org", billingScope: "", mode: .manual)
        _ = try store.importPayments(try PaymentImport.parse("date,amount,currency,kind,account,reference\n2026-01-02,10,USD,top-up,claude-api,A1"))
        XCTAssertEqual(store.state.accounts.count, 1)
        XCTAssertEqual(store.state.payments.first?.accountID, store.state.accounts[0].id)
        let future = "date,amount,currency,kind,account,reference\n2026-01-03,10,USD,top-up,claude-api,A2\n2999-01-01,10,USD,top-up,claude-api,A3"
        XCTAssertThrowsError(try store.importPayments(try PaymentImport.parse(future)))
        XCTAssertEqual(store.state.payments.count, 1, "A rejected file must not save any of its rows")
    }

    func testClaudeCostReportConvertsCentsToDollars() throws {
        let now = Date()
        let today = Calendar.current.startOfDay(for: now)
        let iso = ISO8601DateFormatter()
        let body = """
        {"data":[{"starting_at":"\(iso.string(from: today.addingTimeInterval(-86400)))","ending_at":"\(iso.string(from: today))","results":[{"amount":"1234.5","currency":"USD"}]},
                 {"starting_at":"\(iso.string(from: today))","ending_at":"\(iso.string(from: today.addingTimeInterval(86400)))","results":[{"amount":"250","currency":"USD"}]}],
         "has_more":false,"next_page":null}
        """
        let snapshot = try BalanceClient.decode(integrationID: "claude-api", data: Data(body.utf8), source: URL(string: "https://api.anthropic.com")!, now: now)
        XCTAssertEqual(snapshot.reportedConsumption, [Money(Decimal(string: "14.845")!, "USD")])
        XCTAssertEqual(snapshot.details.first?.value, Money(Decimal(string: "2.5")!, "USD"))
        XCTAssertTrue(snapshot.balances.isEmpty)
    }
}

@MainActor
final class PaymentImportFileTests: XCTestCase {
    /// Opt-in dry run of a real file against an empty store: UNIFAI_TEST_IMPORT_FILE=/path/to/file.csv
    func testImportFileIfRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["UNIFAI_TEST_IMPORT_FILE"] else { throw XCTSkip("Set UNIFAI_TEST_IMPORT_FILE to dry-run an import file.") }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let store = AppStore(repository: StateRepository(directory: root.appendingPathComponent(".build/test-data/\(UUID().uuidString)")), vault: MemoryVault())
        let rows = try PaymentImport.parse(try String(contentsOfFile: path, encoding: .utf8))
        let summary = try store.importPayments(rows)
        print("Import dry run: \(summary.imported) imported, \(summary.duplicates) duplicates, wallets \(summary.createdAccounts)")
        for (currency, records) in Dictionary(grouping: store.state.payments, by: { $0.money.currency }).sorted(by: { $0.key < $1.key }) {
            let byWallet = Dictionary(grouping: records, by: { record in store.state.accounts.first { $0.id == record.accountID }?.integrationID ?? "-" })
            for (wallet, group) in byWallet.sorted(by: { $0.key < $1.key }) {
                print("  \(currency) \(wallet): \(group.count) payments, \(Ledger.paidTotals(group).first?.amount ?? 0)")
            }
        }
        XCTAssertEqual(summary.imported, rows.count)
    }
}
