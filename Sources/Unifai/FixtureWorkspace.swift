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
        // Added separately so existing synthetic workspaces gain the OpenAI connectors too.
        if !store.state.accounts.contains(where: { $0.integrationID == "codex" }) {
            try store.addAccount(integrationID: "codex", label: "Personal", billingScope: "ChatGPT Plus", mode: .live)
        }
        if !store.state.accounts.contains(where: { $0.integrationID == "claude-subscription" }) {
            try store.addAccount(integrationID: "claude-subscription", label: "Personal", billingScope: "Claude subscription", mode: .live)
        }
        if !store.state.accounts.contains(where: { $0.integrationID == "claude-api" }) {
            try store.addAccount(integrationID: "claude-api", label: "Console", billingScope: "Synthetic Claude organization", mode: .live, credential: "fixture-valid")
        }
        if !store.state.accounts.contains(where: { $0.integrationID == "openai-api" }) {
            try store.addAccount(integrationID: "openai-api", label: "Side projects", billingScope: "Synthetic organization", mode: .live, credential: "fixture-valid")
        }
        // Synthetic monthly history so the demo shows a detected subscription.
        if let claude = store.state.accounts.first(where: { $0.integrationID == "claude-subscription" }),
           !store.state.payments.contains(where: { $0.reference.hasPrefix("SYNTHETIC-MAX") }) {
            for (index, monthsAgo) in [3, 2, 1].enumerated() {
                let date = Calendar.current.date(byAdding: .month, value: -monthsAgo, to: .now)!.addingTimeInterval(-86400 * 4)
                try store.savePayment(.init(accountID: claude.id, description: "Claude Max 5x", kind: .subscription, money: Money(Decimal(string: "149.99")!, "SGD"),
                                            paidAt: date, reference: "SYNTHETIC-MAX-\(index)"))
            }
        }
        for account in store.state.accounts where account.mode == .live { try vault.write("fixture-valid", accountID: account.id) }
    }
    static func balance(_ integration: String, _ credential: String, _ now: Date) async throws -> BalanceSnapshot {
        if credential == "fixture-unauthorized" { throw ConnectorError.authorization }
        if credential == "fixture-offline" { throw URLError(.notConnectedToInternet) }
        if integration == "codex" {
            let account = Data(#"{"account":{"type":"chatgpt","email":null,"planType":"plus"},"requiresOpenaiAuth":true}"#.utf8)
            let fiveHour = Int(now.addingTimeInterval(3 * 3600 + 1200).timeIntervalSince1970), weekly = Int(now.addingTimeInterval(3 * 86400 + 7200).timeIntervalSince1970)
            let limits = Data("{\"rateLimits\":{\"limitId\":\"codex\",\"planType\":\"plus\",\"primary\":{\"usedPercent\":42,\"windowDurationMins\":300,\"resetsAt\":\(fiveHour)},\"secondary\":{\"usedPercent\":68,\"windowDurationMins\":10080,\"resetsAt\":\(weekly)},\"credits\":{\"hasCredits\":true,\"unlimited\":false,\"balance\":\"120.50\"}}}".utf8)
            return try CodexClient.decode(account: account, limits: limits, now: now)
        }
        if integration == "claude-subscription" {
            return try ClaudeCodeClient.decode(Data(#"{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"max"}"#.utf8), now: now)
        }
        if integration == "claude-api" {
            let iso = ISO8601DateFormatter(), today = Calendar.current.startOfDay(for: now)
            let buckets = (0..<30).map { day -> String in
                let start = today.addingTimeInterval(TimeInterval((day - 29) * 86400))
                let cents = [412, 0, 1180, 655, 2310, 95][day % 6]
                return "{\"starting_at\":\"\(iso.string(from: start))\",\"ending_at\":\"\(iso.string(from: start.addingTimeInterval(86400)))\",\"results\":[{\"amount\":\"\(cents)\",\"currency\":\"USD\"}]}"
            }
            return try BalanceClient.decode(integrationID: integration, data: Data("{\"data\":[\(buckets.joined(separator: ","))],\"has_more\":false}".utf8), source: URL(string: "https://api.anthropic.com")!, now: now)
        }
        if integration == "openai-api" {
            let today = Int(Calendar.current.startOfDay(for: now).timeIntervalSince1970)
            let buckets = (0..<30).map { day -> String in
                let start = today - (29 - day) * 86400
                let value = day % 3 == 0 ? 0 : [0.42, 1.18, 0.73, 2.05, 0.31][day % 5]
                return "{\"object\":\"bucket\",\"start_time\":\(start),\"end_time\":\(start + 86400),\"results\":[{\"object\":\"organization.costs.result\",\"amount\":{\"value\":\(value),\"currency\":\"usd\"}}]}"
            }
            let body = "{\"object\":\"page\",\"data\":[\(buckets.joined(separator: ","))],\"has_more\":false}"
            return try BalanceClient.decode(integrationID: integration, data: Data(body.utf8), source: URL(string: "https://api.openai.com")!, now: now)
        }
        let body = integration == "openrouter"
            ? #"{"data":{"total_credits":100,"total_usage":30}}"#
            : #"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"110.00","granted_balance":"10.00","topped_up_balance":"100.00"}]}"#
        return try BalanceClient.decode(integrationID: integration, data: Data(body.utf8), source: URL(string: integration == "openrouter" ? "https://openrouter.ai/api/v1/credits" : "https://api.deepseek.com/user/balance")!, now: now)
    }
    /// Synthetic reference rates; the demo never contacts the ECB.
    static func rates(_ currencies: [String], _ since: Date, _ now: Date) async throws -> RateTable {
        let base: [String: Double] = ["USD": 1.08, "SGD": 1.43, "CNY": 7.6, "GBP": 0.85, "JPY": 160]
        var rates: [String: [String: Double]] = [:]
        var day = Calendar.current.startOfDay(for: since).addingTimeInterval(-14 * 86400)
        while day <= now {
            rates[RateTable.dayFormatter.string(from: day)] = base.filter { currencies.contains($0.key) }
            day = day.addingTimeInterval(86400)
        }
        return RateTable(rates: rates, fetchedAt: now, currencies: currencies)
    }

    static func releases(_ repository: WatchedRepository, _ now: Date) async throws -> GitHubFetchResult {
        let data = Data(#"[{"id":123456789,"name":"Synthetic release","tag_name":"v1.0.0","html_url":"https://github.com/example/ai-hub/releases/tag/v1.0.0","published_at":"2026-10-17T08:00:00Z","prerelease":false,"draft":false},{"id":123456790,"name":"Synthetic preview","tag_name":"v1.1.0-beta","html_url":"https://github.com/example/ai-hub/releases/tag/v1.1.0-beta","published_at":"2026-10-18T08:00:00Z","prerelease":true,"draft":false}]"#.utf8)
        return .init(releases: try GitHubClient.decode(data), etag: "fixture-etag", retryAfter: now.addingTimeInterval(1800))
    }
}
