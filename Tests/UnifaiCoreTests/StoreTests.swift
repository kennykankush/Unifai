import XCTest
@testable import UnifaiCore

@MainActor
final class StoreTests: XCTestCase {
    private func repository() -> StateRepository {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return StateRepository(directory: root.appendingPathComponent(".build/test-data/\(UUID().uuidString)"))
    }
    private func sample(_ value: Decimal = 70, now: Date = .now) -> BalanceSnapshot {
        .init(balances: [Money(value, "USD")], reportedConsumption: [Money(30, "USD")], observedAt: now, source: URL(string: "https://example.invalid/fixture")!, coverage: "Synthetic, unknown history")
    }
    func testEmptyStartAndIndependentLabelledAccounts() async throws {
        let repo = repository(); let vault = MemoryVault()
        let store = AppStore(repository: repo, vault: vault)
        XCTAssertEqual(store.state.accounts, []); XCTAssertEqual(store.state.coverageDescription, "No payment history recorded")
        try store.addAccount(integrationID: "openrouter", label: "Personal", billingScope: "one", mode: .live, credential: "fixture-one")
        try store.addAccount(integrationID: "openrouter", label: "Work", billingScope: "two", mode: .live, credential: "fixture-two")
        XCTAssertEqual(store.state.accounts.count, 2)
        XCTAssertEqual(try vault.read(accountID: store.state.accounts[0].id), "fixture-one")
        XCTAssertEqual(try vault.read(accountID: store.state.accounts[1].id), "fixture-two")
        let json = try String(contentsOf: repo.file, encoding: .utf8)
        XCTAssertFalse(json.contains("fixture-one")); XCTAssertFalse(json.contains("fixture-two"))
        XCTAssertEqual(try repo.load(), store.state)
    }
    func testDuplicateBillingOwnerRejectedAndPlannedConnectorRefused() async throws {
        let store = AppStore(repository: repository(), vault: MemoryVault())
        try store.addAccount(integrationID: "openrouter", label: "Personal", billingScope: " Personal ", mode: .live, credential: "fixture")
        XCTAssertThrowsError(try store.addAccount(integrationID: "openrouter", label: "Other key", billingScope: "personal", mode: .live, credential: "fixture"))
        XCTAssertThrowsError(try store.addAccount(integrationID: "openrouter", label: "personal", billingScope: "different", mode: .manual))
        XCTAssertThrowsError(try store.addAccount(integrationID: "claude-api", label: "Org", billingScope: "Org", mode: .live, credential: "fixture"))
        XCTAssertThrowsError(try store.addAccount(integrationID: "deepseek", label: "No owner", billingScope: "", mode: .live, credential: "fixture"))
        XCTAssertThrowsError(try store.addAccount(integrationID: "x-accounts", label: "News", billingScope: "", mode: .manual))
        try store.addAccount(integrationID: "claude-api", label: "Org", billingScope: "", mode: .manual)
        XCTAssertEqual(store.state.accounts.count, 2)
    }
    func testCredentialsRejectControlCharactersAndNeverEnterMetadata() async throws {
        let vault = MemoryVault(); let store = AppStore(repository: repository(), vault: vault)
        XCTAssertThrowsError(try store.addAccount(integrationID: "deepseek", label: "Personal", billingScope: "Personal", mode: .live, credential: "fixture\r\ninjected"))
        XCTAssertTrue(store.state.accounts.isEmpty)
    }
    func testRefreshFailurePreservesSnapshotAndCooldown() async throws {
        let repo = repository(); let vault = MemoryVault(); let expected = sample()
        var fail = false; var count = 0
        let store = AppStore(repository: repo, vault: vault, balances: { _, _, _ in
            count += 1; if fail { throw ConnectorError.authorization }; return expected
        })
        try store.addAccount(integrationID: "openrouter", label: "Personal", billingScope: "one", mode: .live, credential: "fixture")
        let id = store.state.accounts[0].id; let now = Date()
        try store.savePayment(.init(accountID: id, description: "Prepaid purchase", kind: .topUp, money: Money(100, "USD"), paidAt: now))
        await store.refreshAccount(id, now: now)
        XCTAssertEqual(store.state.accounts[0].snapshot, expected)
        fail = true
        await store.refreshAccount(id, now: now.addingTimeInterval(61))
        XCTAssertEqual(store.state.accounts[0].snapshot, expected)
        XCTAssertNotNil(store.state.accounts[0].lastError)
        await store.refreshAccount(id, now: now.addingTimeInterval(62))
        XCTAssertEqual(count, 2)
        XCTAssertEqual(try repo.load().accounts[0].snapshot, expected)
        XCTAssertEqual(Ledger.paidTotals(store.state.payments), [Money(100, "USD")])
    }
    func testMissingCredentialAndRedactedUnexpectedError() async throws {
        let vault = MemoryVault(); let store = AppStore(repository: repository(), vault: vault, balances: { _, _, _ in throw NSError(domain: "fixture-secret-should-never-be-persisted", code: 1) })
        try store.addAccount(integrationID: "deepseek", label: "Personal", billingScope: "one", mode: .live, credential: "fixture")
        let id = store.state.accounts[0].id
        await store.refreshAccount(id)
        XCTAssertFalse(store.state.accounts[0].lastError!.contains("fixture-secret"))
        try vault.delete(accountID: id)
        await store.refreshAccount(id, now: .now.addingTimeInterval(61))
        XCTAssertEqual(store.state.accounts[0].lastError, ConnectorError.missingCredential.localizedDescription)
    }
    func testInFlightRefreshCannotDeleteAccountOrStartDuplicate() async throws {
        let vault = MemoryVault(); let expected = sample()
        var pending: CheckedContinuation<BalanceSnapshot, Error>?
        var count = 0
        let store = AppStore(repository: repository(), vault: vault, balances: { _, _, _ in
            count += 1
            return try await withCheckedThrowingContinuation { pending = $0 }
        })
        try store.addAccount(integrationID: "deepseek", label: "Personal", billingScope: "one", mode: .live, credential: "fixture")
        let id = store.state.accounts[0].id
        let task = Task { await store.refreshAccount(id) }
        while pending == nil { await Task.yield() }
        XCTAssertThrowsError(try store.removeAccount(id))
        XCTAssertThrowsError(try store.updateAccount(id, label: "Other", credential: "fixture-new"))
        await store.refreshAccount(id)
        XCTAssertEqual(count, 1)
        pending?.resume(returning: expected)
        await task.value
        XCTAssertEqual(store.state.accounts[0].snapshot, expected)
    }
    func testPaymentEditDedupRefundAndCoverage() async throws {
        let repo = repository(); let store = AppStore(repository: repo, vault: MemoryVault())
        let now = Date(); var payment = PaymentRecord(description: "Top-up", kind: .topUp, money: Money(100, "USD"), paidAt: now.addingTimeInterval(-10), reference: "receipt")
        try store.savePayment(payment, now: now)
        try store.savePayment(payment, now: now)
        XCTAssertEqual(store.state.payments.count, 1)
        try store.setCoverage(start: now.addingTimeInterval(-20), complete: true, now: now)
        payment.money = Money(90, "USD"); try store.savePayment(payment, now: now)
        XCTAssertEqual(Ledger.paidTotals(store.state.payments, through: now), [Money(90, "USD")])
        let earlier = PaymentRecord(description: "Refund", kind: .refund, money: Money(10, "USD"), paidAt: now.addingTimeInterval(-30))
        try store.savePayment(earlier, now: now)
        XCTAssertEqual(store.state.historyCoverage?.start, earlier.paidAt)
        XCTAssertEqual(store.state.historyCoverage?.completeForPeriod, false)
        XCTAssertEqual(Ledger.paidTotals(store.state.payments, through: now), [Money(80, "USD")])
        XCTAssertThrowsError(try store.setCoverage(start: now, complete: true))
        XCTAssertEqual(try repo.load(), store.state)
    }
    func testSchedulesNeverInventPaymentsAndLinkedAccountRemovalIsRefused() async throws {
        let store = AppStore(repository: repository(), vault: MemoryVault())
        try store.addAccount(integrationID: "chatgpt", label: "Personal", billingScope: "Shared with Codex", mode: .manual)
        let accountID = store.state.accounts[0].id
        let schedule = SubscriptionSchedule(accountID: accountID, name: "ChatGPT", price: Money(20, "USD"), cadence: .monthly, nextRenewal: .distantPast)
        try store.saveSubscription(schedule)
        XCTAssertTrue(store.state.payments.isEmpty)
        XCTAssertThrowsError(try store.removeAccount(accountID))
        try store.removeSubscription(schedule.id); try store.removeAccount(accountID)
        XCTAssertTrue(store.state.accounts.isEmpty)
        XCTAssertThrowsError(try store.saveSubscription(.init(name: "", price: Money(0, "USD"), cadence: .monthly, nextRenewal: .now)))
    }
    func testSaveFailureRollsBackStateAndNewCredential() async throws {
        let repo = repository(); try FileManager.default.createDirectory(at: repo.directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("blocking-file".utf8).write(to: repo.directory)
        let vault = MemoryVault()
        // Missing state.json loads empty; saving cannot create a directory over this file.
        let store = AppStore(repository: repo, vault: vault)
        XCTAssertThrowsError(try store.addAccount(integrationID: "openrouter", label: "Personal", billingScope: "one", mode: .live, credential: "fixture"))
        XCTAssertTrue(store.state.accounts.isEmpty)
        XCTAssertEqual(try Data(contentsOf: repo.directory), Data("blocking-file".utf8))
    }
    func testCorruptOrFutureSchemaIsPreservedAndWritesDisabled() async throws {
        for data in [Data("broken-json".utf8), Data(#"{"schemaVersion":999,"accounts":[],"payments":[],"subscriptions":[],"repositories":[]}"#.utf8)] {
            let repo = repository(); try FileManager.default.createDirectory(at: repo.directory, withIntermediateDirectories: true)
            try data.write(to: repo.file)
            let store = AppStore(repository: repo, vault: MemoryVault())
            XCTAssertNotNil(store.loadFailure)
            XCTAssertThrowsError(try store.addRepository("example/project", includePrereleases: false))
            XCTAssertEqual(try Data(contentsOf: repo.file), data)
        }
    }
    func testScaffoldSchemaLoadsAndFilePermissionsArePrivate() async throws {
        let repo = repository(); try FileManager.default.createDirectory(at: repo.directory, withIntermediateDirectories: true)
        try Data(#"{"schemaVersion":1,"accounts":[],"payments":[],"subscriptions":[],"repositories":[]}"#.utf8).write(to: repo.file)
        XCTAssertEqual(try repo.load(), PersistentState())
        try repo.save(PersistentState())
        let attributes = try FileManager.default.attributesOfItem(atPath: repo.file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testRepositoryLimitDuplicatesAndCooldownSurviveRestart() async throws {
        let repo = repository(); var count = 0
        let loader: AppStore.ReleaseLoader = { _, now in count += 1; return .init(releases: [], etag: "fixture", retryAfter: now.addingTimeInterval(1800)) }
        let store = AppStore(repository: repo, vault: MemoryVault(), releases: loader)
        for i in 0..<10 { try store.addRepository("example/project-\(i)", includePrereleases: false) }
        XCTAssertThrowsError(try store.addRepository("example/eleven", includePrereleases: false))
        XCTAssertThrowsError(try store.addRepository("EXAMPLE/PROJECT-0", includePrereleases: false))
        let id = store.state.repositories[0].id; let now = Date()
        await store.refreshRepository(id, now: now)
        let reloaded = AppStore(repository: repo, vault: MemoryVault(), releases: loader)
        await reloaded.refreshRepository(id, now: now.addingTimeInterval(1))
        XCTAssertEqual(count, 1); XCTAssertEqual(reloaded.state.repositories[0].etag, "fixture")
    }
    func testRepository304RetainsReleaseAndPrereleaseFilter() async throws {
        let repo = repository(); var state = PersistentState(); var watched = WatchedRepository(slug: "example/project")
        watched.releases = [.init(id: 1, title: "Stable", tag: "v1", url: URL(string: "https://github.com/example/project/releases/tag/v1")!, publishedAt: .now, prerelease: false),
                            .init(id: 2, title: "Preview", tag: "v2", url: URL(string: "https://github.com/example/project/releases/tag/v2")!, publishedAt: .now, prerelease: true)]
        watched.etag = "fixture"; state.repositories = [watched]; try repo.save(state)
        let store = AppStore(repository: repo, vault: MemoryVault(), releases: { _, now in .init(releases: nil, etag: "fixture", retryAfter: now.addingTimeInterval(1800)) })
        await store.refreshRepository(watched.id)
        XCTAssertEqual(store.state.repositories[0].releases.count, 2)
        XCTAssertEqual(store.state.visibleReleases(for: store.state.repositories[0]).count, 1)
        try store.setPrereleases(watched.id, include: true)
        XCTAssertEqual(store.state.visibleReleases(for: store.state.repositories[0]).count, 2)
    }
    func testGitHubGlobalBudgetAndBackoffArePersisted() async throws {
        let repo = repository(); var state = PersistentState(); let now = Date()
        let a = WatchedRepository(slug: "example/a"), b = WatchedRepository(slug: "example/b")
        state.repositories = [a, b]; try repo.save(state)
        let store = AppStore(repository: repo, vault: MemoryVault(), releases: { _, _ in throw ConnectorError.retryAt(now.addingTimeInterval(7200)) })
        await store.refreshRepository(a.id, now: now)
        XCTAssertEqual(store.state.githubBackoffUntil, now.addingTimeInterval(7200))
        var count = 0
        let restarted = AppStore(repository: repo, vault: MemoryVault(), releases: { _, date in count += 1; return .init(releases: [], etag: nil, retryAfter: date) })
        await restarted.refreshRepository(b.id, now: now.addingTimeInterval(1))
        XCTAssertEqual(count, 0)
        state.githubBackoffUntil = nil; state.githubRequests = Array(repeating: now, count: 20); try repo.save(state)
        let budgeted = AppStore(repository: repo, vault: MemoryVault(), releases: { _, date in count += 1; return .init(releases: [], etag: nil, retryAfter: date) })
        await budgeted.refreshRepository(b.id, now: now)
        XCTAssertEqual(count, 0); XCTAssertTrue(budgeted.notice!.contains("20"))
    }
    func testCredentialReplacementAndAccountDeletionAreScoped() async throws {
        let vault = MemoryVault(); let repo = repository(); let store = AppStore(repository: repo, vault: vault)
        try store.addAccount(integrationID: "deepseek", label: "A", billingScope: "A", mode: .live, credential: "fixture-a")
        try store.addAccount(integrationID: "deepseek", label: "B", billingScope: "B", mode: .live, credential: "fixture-b")
        let a = store.state.accounts[0].id, b = store.state.accounts[1].id
        try store.updateAccount(a, label: "Renamed", credential: "fixture-new")
        XCTAssertEqual(try vault.read(accountID: a), "fixture-new"); XCTAssertEqual(try vault.read(accountID: b), "fixture-b")
        try store.removeAccount(a)
        XCTAssertNil(try vault.read(accountID: a)); XCTAssertEqual(try vault.read(accountID: b), "fixture-b")
        XCTAssertFalse(try String(contentsOf: repo.file, encoding: .utf8).contains("fixture-new"))
    }
    func testConcurrentRateLimitsKeepTheLongestBackoff() async throws {
        let repo = repository(); let now = Date()
        var initial = PersistentState()
        let a = WatchedRepository(slug: "example/a"), b = WatchedRepository(slug: "example/b")
        initial.repositories = [a, b]; try repo.save(initial)
        var pending: [UUID: CheckedContinuation<GitHubFetchResult, Error>] = [:]
        let store = AppStore(repository: repo, vault: MemoryVault(), releases: { repository, _ in
            try await withCheckedThrowingContinuation { pending[repository.id] = $0 }
        })
        let first = Task { await store.refreshRepository(a.id, now: now) }
        let second = Task { await store.refreshRepository(b.id, now: now) }
        while pending.count < 2 { await Task.yield() }
        pending[a.id]?.resume(throwing: ConnectorError.retryAt(now.addingTimeInterval(7200)))
        await first.value
        pending[b.id]?.resume(throwing: ConnectorError.retryAt(now.addingTimeInterval(1800)))
        await second.value
        XCTAssertEqual(store.state.githubBackoffUntil, now.addingTimeInterval(7200))
        XCTAssertEqual(try repo.load().githubBackoffUntil, now.addingTimeInterval(7200))
    }
}
