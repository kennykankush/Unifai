import XCTest
@testable import UnifaiCore

@MainActor
final class CloudAndBudgetTests: XCTestCase {
    private func store(balances: AppStore.BalanceLoader? = nil) -> AppStore {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let repository = StateRepository(directory: root.appendingPathComponent(".build/test-data/\(UUID().uuidString)"))
        if let balances { return AppStore(repository: repository, vault: MemoryVault(), balances: balances) }
        return AppStore(repository: repository, vault: MemoryVault())
    }

    func testAzureDecodeSumsServicesPerCurrencyAndKeepsTopThree() throws {
        let one = Data(#"{"properties":{"columns":[{"name":"Cost","type":"Number"},{"name":"ServiceName","type":"String"},{"name":"Currency","type":"String"}],"rows":[[8.355147342,"Virtual Machines","USD"],[7.1107275,"Foundry Models","USD"],[1.05303448,"Storage","USD"],[0.627265277777778,"Virtual Network","USD"],[0.00022607481234336,"Azure Cognitive Search","USD"]]}}"#.utf8)
        let two = Data(#"{"properties":{"columns":[{"name":"PreTaxCost","type":"Number"},{"name":"ServiceName","type":"String"},{"name":"Currency","type":"String"}],"rows":[[2,"Virtual Machines","USD"]]}}"#.utf8)
        let snapshot = try AzureCostClient.decode([("Sub 1", one), ("Sub 2", two)])
        XCTAssertEqual(snapshot.reportedConsumption.count, 1)
        XCTAssertEqual(NSDecimalNumber(decimal: snapshot.reportedConsumption[0].amount).doubleValue, 19.146, accuracy: 0.001)
        XCTAssertEqual(snapshot.details.map(\.label), ["Virtual Machines", "Foundry Models", "Storage"])
        XCTAssertEqual(NSDecimalNumber(decimal: snapshot.details[0].value.amount).doubleValue, 10.355, accuracy: 0.001)
        XCTAssertEqual(snapshot.consumptionPeriod, "This month")
        XCTAssertTrue(snapshot.coverage.contains("2 enabled subscriptions"))
        XCTAssertThrowsError(try AzureCostClient.decode([("Bad", Data("{}".utf8))]))
    }

    func testAzureIsACredentialFreeCloudWallet() throws {
        let store = store()
        try store.addAccount(integrationID: "azure-subscription", label: "Personal", billingScope: "Azure", mode: .live)
        XCTAssertEqual(store.state.accounts.first?.mode, .live)
        XCTAssertEqual(Catalogue.integration("azure-subscription")?.category, .cloud)
        try store.addAccount(integrationID: "vercel", label: "Hobby", billingScope: "", mode: .manual)
        XCTAssertThrowsError(try store.addAccount(integrationID: "azure-subscription", label: "Second", billingScope: "Other", mode: .live))
    }

    func testBackgroundRefreshOnlyTouchesStaleLiveWallets() async throws {
        var calls: [String] = []
        let store = store { id, _, now in
            calls.append(id)
            return BalanceSnapshot(balances: [Money(5, "USD")], observedAt: now, source: URL(string: "https://example.invalid")!, coverage: "Synthetic")
        }
        try store.addAccount(integrationID: "openrouter", label: "A", billingScope: "a", mode: .live, credential: "k")
        try store.addAccount(integrationID: "deepseek", label: "B", billingScope: "b", mode: .live, credential: "k")
        try store.addAccount(integrationID: "chatgpt", label: "C", billingScope: "", mode: .manual)
        await store.refreshStaleAccounts()
        XCTAssertEqual(calls.sorted(), ["deepseek", "openrouter"])
        await store.refreshStaleAccounts()
        XCTAssertEqual(calls.count, 2, "Fresh readings are not refreshed again")
        try store.setAutoRefresh(false)
        await store.refreshStaleAccounts(olderThan: 0)
        XCTAssertEqual(calls.count, 2, "Disabled")
    }

    func testMonthToDateSpendAgainstBudget() throws {
        let store = store()
        let now = Date()
        try store.savePayment(.init(description: "A", kind: .subscription, money: Money(30, "SGD"), paidAt: now.addingTimeInterval(-60), reference: "1"), now: now)
        try store.savePayment(.init(description: "B", kind: .topUp, money: Money(10, "USD"), paidAt: now.addingTimeInterval(-60), reference: "2"), now: now)
        try store.savePayment(.init(description: "Old", kind: .topUp, money: Money(99, "SGD"), paidAt: now.addingTimeInterval(-86400 * 70), reference: "3"), now: now)
        try store.setMonthlyBudget(Money(400, "SGD"))
        let unconverted = store.state.monthToDateSpend(in: "SGD", rates: nil, now: now)
        XCTAssertEqual(unconverted.spent, Money(30, "SGD")); XCTAssertFalse(unconverted.complete)
        let today = RateTable.dayFormatter.string(from: now)
        let rates = RateTable(rates: [today: ["USD": 1.0, "SGD": 1.3]], fetchedAt: now, currencies: ["USD", "SGD"])
        let converted = store.state.monthToDateSpend(in: "SGD", rates: rates, now: now)
        XCTAssertEqual(converted.spent, Money(43, "SGD")); XCTAssertTrue(converted.complete)
        XCTAssertThrowsError(try store.setMonthlyBudget(Money(0, "SGD")))
    }

    /// Opt-in: reads month-to-date cost through the local Azure CLI. Run with UNIFAI_TEST_AZURE=1.
    func testLiveAzureIfRequested() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["UNIFAI_TEST_AZURE"] == "1", "Set UNIFAI_TEST_AZURE=1 to query Azure Cost Management via az.")
        let snapshot: BalanceSnapshot
        do { snapshot = try await AzureCostClient().fetch() }
        catch ConnectorError.rateLimited { throw XCTSkip("Azure Cost Management is throttling this subscription; try again in a minute.") }
        print("Azure live: \(snapshot.reportedConsumption.map { "\($0.amount) \($0.currency)" }), top \(snapshot.details.map(\.label)), spikes \(snapshot.anomalies?.map(\.summary) ?? ["none"])")
        XCTAssertFalse(snapshot.reportedConsumption.isEmpty)
    }
}

extension CloudAndBudgetTests {
    func testAzureMultiFactorPromptIsExplained() {
        let long = "ERROR: AADSTS50076: Due to a configuration change made by your administrator, or because you moved to a new location, you must use multi-factor authentication to access '797f4846'. Trace ID: x Correlation ID: y Timestamp: 2026-10-19 18:05:18Z\nRun the command below to authenticate interactively; additional arguments may be added as needed:\naz logout\naz login --tenant \"t\""
        XCTAssertTrue((AzureCostClient.cliError(long) as? ValidationError)?.errorDescription?.contains("multi-factor") == true)
    }

    @MainActor
    func testSwitchToManualKeepsRecordsAndDropsTheKey() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let vault = MemoryVault()
        let store = AppStore(repository: StateRepository(directory: root.appendingPathComponent(".build/test-data/\(UUID().uuidString)")), vault: vault)
        try store.addAccount(integrationID: "claude-api", label: "Dev", billingScope: "Hadi", mode: .live, credential: "sk-ant-api-key")
        let id = store.state.accounts[0].id
        try store.savePayment(.init(accountID: id, description: "Claude API credits", kind: .topUp, money: Money(Decimal(string: "10.9")!, "USD"), paidAt: .now.addingTimeInterval(-86400)))
        try store.switchToManual(id)
        XCTAssertEqual(store.state.accounts[0].mode, .manual)
        XCTAssertNil(store.state.accounts[0].lastError)
        XCTAssertEqual(store.state.payments.count, 1)
        XCTAssertNil(try vault.read(accountID: id))
    }
}

extension CloudAndBudgetTests {
    func testAzureResourcesJoinCostsInventoryStatesAndModels() {
        let sub = "/subscriptions/s1/resourceGroups/ML-Lab/providers/Microsoft.Compute/virtualMachines/gpu-01"
        let foundry = "/subscriptions/s1/resourceGroups/ai/providers/Microsoft.CognitiveServices/accounts/hadi-foundry"
        let gone = "/subscriptions/s1/resourcegroups/dev/providers/microsoft.compute/virtualmachines/old-box"
        var extras = AzureCostClient.Extras()
        extras.resourceCosts = [Data("""
        {"properties":{"columns":[{"name":"Cost"},{"name":"ResourceId"},{"name":"Meter"},{"name":"Currency"}],"rows":[
         [8.44,"\(sub.lowercased())","NC6s v3","USD"],[1.2,"\(sub.lowercased())","P30 LRS Disk","USD"],
         [3.2,"\(foundry.lowercased())","gpt-4.1-mini Inp glbl Tokens","USD"],[0.4,"\(gone)","D2s v5","USD"]]}}
        """.utf8)]
        extras.resources = [Data("""
        [{"id":"\(sub)","name":"gpu-01","type":"Microsoft.Compute/virtualMachines","location":"eastus","resourceGroup":"ML-Lab","sku":null},
         {"id":"\(foundry)","name":"hadi-foundry","type":"Microsoft.CognitiveServices/accounts","location":"eastus2","resourceGroup":"ai","sku":"S0"},
         {"id":"/subscriptions/s1/resourceGroups/dev/providers/Microsoft.Compute/virtualMachines/dev-box","name":"dev-box","type":"Microsoft.Compute/virtualMachines","location":"southeastasia","resourceGroup":"dev","sku":null}]
        """.utf8)]
        extras.resourceListRead = true
        extras.machines = [Data(#"[{"id":"\#(sub)","power":"VM running","size":"Standard_NC6s_v3"},{"id":"/subscriptions/s1/resourceGroups/dev/providers/Microsoft.Compute/virtualMachines/dev-box","power":"VM deallocated","size":"Standard_D4s_v5"}]"#.utf8)]
        extras.deployments = [foundry.lowercased(): Data(#"[{"name":"gpt-4.1-mini","model":"gpt-4.1-mini","version":"2025-04-14","sku":"GlobalStandard","capacity":50}]"#.utf8)]

        let resources = AzureCostClient.resources(extras, currency: "USD")
        XCTAssertEqual(resources.map(\.name), ["gpu-01", "hadi-foundry", "old-box", "dev-box"], "Costliest first; resources without cost last")
        XCTAssertEqual(resources[0].cost, Money(Decimal(string: "9.64")!, "USD"))
        XCTAssertEqual(resources[0].state, "Running")
        XCTAssertEqual(resources[0].size, "Standard_NC6s_v3")
        XCTAssertEqual(resources[0].meters.first?.name, "NC6s v3")
        XCTAssertEqual(resources[0].kind, "Virtual machine")
        XCTAssertEqual(resources[1].models?.first?.capacity, 50)
        XCTAssertEqual(resources[1].family, "AI")
        XCTAssertEqual(resources[2].state, "Deleted", "Billed this month but no longer listed")
        XCTAssertEqual(resources[2].type, "microsoft.compute/virtualmachines")
        XCTAssertEqual(resources[3].state, "Deallocated")
        XCTAssertNil(resources[3].cost)
    }
}
