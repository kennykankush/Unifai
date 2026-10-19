import XCTest
@testable import UnifaiCore

final class WidgetSnapshotTests: XCTestCase {
    func testSnapshotRoundTripsAndBudgetShare() throws {
        let spend = WidgetSnapshot.Spend(thisMonth: Money(300, "SGD"), accruing: Money(Decimal(string: "17.15")!, "SGD"), budget: Money(400, "SGD"),
                                         months: [1, 2, 3, 4, 5, 300], monthLabels: ["M", "J", "J", "A", "S", "O"], complete: true)
        XCTAssertEqual(spend.budgetUsed, 0.75)
        let snapshot = WidgetSnapshot(generatedAt: Date(timeIntervalSince1970: 1_792_000_000), spend: spend, nextRenewal: nil,
                                      wallets: [.init(id: "a", name: "Codex", label: "Personal", logo: "codex-color", colors: [1, 2, 3], caption: "Codex credits",
                                                      value: Money(Decimal(string: "187.92")!, "CREDITS"), text: nil,
                                                      windows: [.init(name: "Week", usedPercent: 100, resetsAt: nil)], status: "Limit reached", alert: true)],
                                      room: [], events: [])
        let data = try WidgetStore.encoder().encode(snapshot)
        XCTAssertEqual(try WidgetStore.decoder().decode(WidgetSnapshot.self, from: data), snapshot)
        XCTAssertNil(WidgetSnapshot.Spend(thisMonth: Money(1, "USD"), accruing: nil, budget: nil, months: [], monthLabels: [], complete: true).budgetUsed)
    }

    func testNoAppGroupMeansNoWidgetFile() {
        // The test runner's bundle has no UnifaiAppGroup, like an ad-hoc build: publishing is a no-op.
        XCTAssertNil(WidgetStore.fileURL(bundle: Bundle(for: Self.self)))
    }
}
