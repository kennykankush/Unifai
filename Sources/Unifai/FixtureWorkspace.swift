import Foundation
import UnifaiCore

// Explicit opt-in only. This transport never creates URLSession or reads Keychain.
enum FixtureWorkspace {
    static func checkNativeKeychain(directory: URL) {
        let vault = KeychainVault(service: "dev.unifai.synthetic-native-check.\(UUID().uuidString)")
        let a = UUID(), b = UUID()
        var results: [String: String] = ["scope": "Unique synthetic test service; no ambient credentials read", "time": Date.now.ISO8601Format()]
        do {
            guard try vault.read(accountID: a) == nil else { throw ValidationError.message("Expected a new item.") }
            try vault.write("synthetic-a", accountID: a); try vault.write("synthetic-b", accountID: b)
            guard try vault.read(accountID: a) == "synthetic-a", try vault.read(accountID: b) == "synthetic-b" else { throw ValidationError.message("Isolation check failed.") }
            try vault.write("synthetic-replaced", accountID: a)
            guard try vault.read(accountID: a) == "synthetic-replaced", try vault.read(accountID: b) == "synthetic-b" else { throw ValidationError.message("Replacement check failed.") }
            try vault.delete(accountID: a); try vault.delete(accountID: b)
            guard try vault.read(accountID: a) == nil, try vault.read(accountID: b) == nil else { throw ValidationError.message("Deletion check failed.") }
            results["result"] = "PASS: create, read, replace, isolate, delete"
        } catch {
            results["result"] = "FAIL: \(error.localizedDescription)"
            do { try vault.delete(accountID: a); try vault.delete(accountID: b) }
            catch { results["cleanup"] = error.localizedDescription }
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(results).write(to: directory.appendingPathComponent("native-keychain-check.json"), options: .atomic)
        } catch { NSLog("Could not save the synthetic Keychain check result.") }
    }
    @MainActor static func prepare(_ store: AppStore, vault: MemoryVault) throws {
        if store.state.accounts.isEmpty && store.state.payments.isEmpty && store.state.repositories.isEmpty {
            try store.addAccount(integrationID: "openrouter", label: "Personal", billingScope: "Personal billing", mode: .live, credential: "fixture-valid")
            try store.addAccount(integrationID: "openrouter", label: "Experiments", billingScope: "Experiment billing", mode: .live, credential: "fixture-valid")
            try store.addAccount(integrationID: "deepseek", label: "Personal", billingScope: "DeepSeek personal", mode: .live, credential: "fixture-valid")
            try store.addAccount(integrationID: "chatgpt", label: "Personal subscription", billingScope: "Shared with Codex", mode: .manual)
            try store.savePayment(.init(accountID: store.state.accounts[0].id, description: "OpenRouter credit purchase", kind: .topUp, money: Money(100, "USD"), paidAt: .now.addingTimeInterval(-86400 * 10), reference: "SYNTHETIC-001"))
            try store.savePayment(.init(accountID: store.state.accounts[3].id, description: "ChatGPT subscription", kind: .subscription, money: Money(20, "USD"), paidAt: .now.addingTimeInterval(-86400 * 5), reference: "SYNTHETIC-002"))
            try store.savePayment(.init(accountID: store.state.accounts[2].id, description: "DeepSeek credit purchase", kind: .topUp, money: Money(100, "CNY"), paidAt: .now.addingTimeInterval(-86400 * 2), reference: "SYNTHETIC-003"))
            try store.saveSubscription(.init(accountID: store.state.accounts[3].id, name: "ChatGPT", price: Money(20, "USD"), cadence: .monthly, nextRenewal: .now.addingTimeInterval(86400 * 25)))
            try store.addRepository("example/ai-hub", includePrereleases: false)
        }
        for account in store.state.accounts where account.mode == .live { try vault.write("fixture-valid", accountID: account.id) }
    }
    static func balance(_ integration: String, _ credential: String, _ now: Date) async throws -> BalanceSnapshot {
        if credential == "fixture-unauthorized" { throw ConnectorError.authorization }
        if credential == "fixture-offline" { throw URLError(.notConnectedToInternet) }
        let body = integration == "openrouter"
            ? #"{"data":{"total_credits":100,"total_usage":30}}"#
            : #"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"110.00","granted_balance":"10.00","topped_up_balance":"100.00"}]}"#
        return try BalanceClient.decode(integrationID: integration, data: Data(body.utf8), source: URL(string: integration == "openrouter" ? "https://openrouter.ai/api/v1/credits" : "https://api.deepseek.com/user/balance")!, now: now)
    }
    static func releases(_ repository: WatchedRepository, _ now: Date) async throws -> GitHubFetchResult {
        let data = Data(#"[{"id":123456789,"name":"Synthetic release","tag_name":"v1.0.0","html_url":"https://github.com/example/ai-hub/releases/tag/v1.0.0","published_at":"2026-10-17T08:00:00Z","prerelease":false,"draft":false},{"id":123456790,"name":"Synthetic preview","tag_name":"v1.1.0-beta","html_url":"https://github.com/example/ai-hub/releases/tag/v1.1.0-beta","published_at":"2026-10-18T08:00:00Z","prerelease":true,"draft":false}]"#.utf8)
        return .init(releases: try GitHubClient.decode(data), etag: "fixture-etag", retryAfter: now.addingTimeInterval(1800))
    }
}
