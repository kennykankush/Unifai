import Foundation

public enum ConnectorError: LocalizedError, Equatable {
    case authorization, rateLimited, unavailable(Int), invalidResponse, missingCredential
    case retryAt(Date)
    public var errorDescription: String? {
        switch self {
        case .authorization: return "Access was refused. Check the key and its billing permissions. OpenRouter account credits require a management key."
        case .rateLimited: return "The service rate limit was reached. Wait before refreshing again."
        case .retryAt(let date): return "The service rate limit was reached. Try again after \(date.formatted(date: .omitted, time: .shortened))."
        case .unavailable(let status): return "The service returned HTTP \(status). The last successful reading is preserved."
        case .invalidResponse: return "The service returned an unexpected response. No balance was replaced."
        case .missingCredential: return "The account credential is missing from Keychain. Replace it to refresh this account."
        }
    }
}

public struct BalanceClient {
    private let session: URLSession
    public init(session: URLSession = BalanceClient.privateSession()) { self.session = session }
    public static func privateSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }
    public func fetch(integrationID: String, credential: String, now: Date = .now) async throws -> BalanceSnapshot {
        if integrationID == "codex" { return try await CodexClient().fetch(now: now) }
        if integrationID == "claude-subscription" { return try await ClaudeCodeClient().fetch(now: now) }
        if integrationID == "azure-subscription" { return try await AzureCostClient().fetch(now: now) }
        guard !credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ConnectorError.missingCredential }
        let endpoint: String
        switch integrationID {
        case "openrouter": endpoint = "https://openrouter.ai/api/v1/credits"
        case "deepseek": endpoint = "https://api.deepseek.com/user/balance"
        case "openai-api":
            // Costs for the last 30 full and partial UTC days, one bucket per day.
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
            let start = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now))!
            endpoint = "https://api.openai.com/v1/organization/costs?start_time=\(Int(start.timeIntervalSince1970))&bucket_width=1d&limit=31"
        case "claude-api":
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
            let start = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now))!
            endpoint = "https://api.anthropic.com/v1/organizations/cost_report?starting_at=\(start.ISO8601Format())&bucket_width=1d&limit=31"
        default: throw ValidationError.message("This service does not have a live balance connector yet.")
        }
        let url = URL(string: endpoint)!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if integrationID == "claude-api" {
            request.setValue(credential, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.setValue("Unifai/1 (https://github.com/kennykankush/Unifai)", forHTTPHeaderField: "User-Agent")
        } else {
            request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ConnectorError.invalidResponse }
        switch response.statusCode {
        case 200..<300: break
        case 401 where integrationID == "claude-api", 403 where integrationID == "claude-api":
            throw ValidationError.message("Anthropic refused the key. The Cost API needs an Admin key (sk-ant-admin01-...) from Console > Settings > Admin keys, which requires an organization rather than an individual account.")
        case 401 where integrationID == "openai-api", 403 where integrationID == "openai-api":
            throw ValidationError.message("OpenAI refused the key. The Costs API needs an organization Admin key (sk-admin-...) from platform.openai.com > Settings > Organization > Admin keys.")
        case 401, 403: throw ConnectorError.authorization
        case 429: throw ConnectorError.rateLimited
        default: throw ConnectorError.unavailable(response.statusCode)
        }
        return try Self.decode(integrationID: integrationID, data: data, source: url, now: now)
    }
    public static func decode(integrationID: String, data: Data, source: URL, now: Date = .now) throws -> BalanceSnapshot {
        do {
            if integrationID == "claude-api" {
                let body = try JSONDecoder().decode(AnthropicCostReport.self, from: data)
                var totals: [String: Decimal] = [:], latest: [String: Decimal] = [:]
                let todayStart = Calendar.current.startOfDay(for: now)
                for bucket in body.data {
                    let ending = ISO8601DateFormatter().date(from: bucket.ending_at) ?? .distantPast
                    for result in bucket.results {
                        // Amounts are decimal strings in the lowest currency unit (cents).
                        guard let cents = Decimal(string: result.amount, locale: Locale(identifier: "en_US_POSIX")), !cents.isNaN, cents >= 0 else { throw ConnectorError.invalidResponse }
                        let currency = result.currency.uppercased()
                        guard Money.validCurrency(currency) else { throw ConnectorError.invalidResponse }
                        totals[currency, default: 0] += cents / 100
                        if ending > todayStart { latest[currency, default: 0] += cents / 100 }
                    }
                }
                if totals.isEmpty { totals["USD"] = 0 }
                return BalanceSnapshot(balances: [], details: latest.keys.sorted().map { BalanceDetail("Latest day", Money(latest[$0]!, $0)) },
                                       reportedConsumption: totals.keys.sorted().map { Money(totals[$0]!, $0) }, observedAt: now,
                                       source: URL(string: "https://platform.claude.com/docs/en/manage-claude/usage-cost-api")!,
                                       coverage: "Anthropic Cost API totals for the last 30 days, by UTC day. Priority Tier costs are excluded, and Anthropic offers no remaining-credit endpoint. Claude subscriptions are separate.",
                                       consumptionPeriod: "Last 30 days")
            }
            if integrationID == "openai-api" {
                let body = try JSONDecoder().decode(OpenAICostsPage.self, from: data)
                var totals: [String: Decimal] = [:]
                var today: [String: Decimal] = [:]
                let todayStart = Int(Calendar.current.startOfDay(for: now).timeIntervalSince1970)
                for bucket in body.data {
                    for result in bucket.results {
                        guard let amount = result.amount, amount.value.isFinite, amount.value >= 0 else { continue }
                        let currency = amount.currency.uppercased()
                        guard Money.validCurrency(currency) else { throw ConnectorError.invalidResponse }
                        let value = Decimal(string: String(amount.value)) ?? Decimal(amount.value)
                        totals[currency, default: 0] += value
                        if bucket.end_time > todayStart { today[currency, default: 0] += value }
                    }
                }
                if totals.isEmpty { totals["USD"] = 0 }
                let consumption = totals.keys.sorted().map { Money(totals[$0]!, $0) }
                let details = today.keys.sorted().map { BalanceDetail("Latest day", Money(today[$0]!, $0)) }
                return BalanceSnapshot(balances: [], details: details, reportedConsumption: consumption, observedAt: now,
                                       source: URL(string: "https://platform.openai.com/docs/api-reference/usage/costs")!,
                                       coverage: "OpenAI Costs API totals for the last 30 days, grouped by UTC day. Costs can be reported with a delay and exclude ChatGPT subscriptions. OpenAI offers no prepaid balance endpoint.",
                                       consumptionPeriod: "Last 30 days")
            }
            if integrationID == "openrouter" {
                let body = try JSONDecoder().decode(OpenRouterResponse.self, from: data).data
                guard !body.total_credits.isNaN, !body.total_usage.isNaN,
                      body.total_credits >= 0, body.total_usage >= 0 else { throw ConnectorError.invalidResponse }
                return BalanceSnapshot(balances: [Money(body.total_credits - body.total_usage, "USD")],
                                       details: [BalanceDetail("Reported credits purchased", Money(body.total_credits, "USD"))],
                                       reportedConsumption: [Money(body.total_usage, "USD")], observedAt: now, source: source,
                                       coverage: "Provider-reported credit totals at retrieval. The endpoint supplies no daily history or cash receipts; the consumption coverage start is unknown.")
            }
            guard integrationID == "deepseek" else { throw ConnectorError.invalidResponse }
            let body = try JSONDecoder().decode(DeepSeekResponse.self, from: data)
            guard !body.balance_infos.isEmpty else { throw ConnectorError.invalidResponse }
            var balances: [Money] = []; var details: [BalanceDetail] = []
            var currencies = Set<String>()
            for info in body.balance_infos {
                guard Money.validCurrency(info.currency), currencies.insert(info.currency.uppercased()).inserted,
                      let total = Self.balanceNumber(info.total_balance),
                      let granted = Self.balanceNumber(info.granted_balance),
                      let purchased = Self.balanceNumber(info.topped_up_balance),
                      !total.isNaN, !granted.isNaN, !purchased.isNaN else { throw ConnectorError.invalidResponse }
                balances.append(Money(total, info.currency))
                details.append(BalanceDetail("Promotional balance", Money(granted, info.currency)))
                details.append(BalanceDetail("Purchased balance", Money(purchased, info.currency)))
            }
            return BalanceSnapshot(balances: balances, details: details, observedAt: now, source: source,
                                   coverage: "Current balances only. Historical computation and cash payments are unavailable. Service availability: \(body.is_available ? "available" : "unavailable").")
        } catch let error as ConnectorError { throw error }
        catch { throw ConnectorError.invalidResponse }
    }
    private static func balanceNumber(_ string: String) -> Decimal? {
        guard string.count <= 30, string.range(of: #"^-?[0-9]+(\.[0-9]{1,12})?$"#, options: .regularExpression) != nil else { return nil }
        return Decimal(string: string, locale: Locale(identifier: "en_US_POSIX"))
    }
    private struct OpenRouterResponse: Decodable {
        struct Credits: Decodable { let total_credits: Decimal; let total_usage: Decimal }
        let data: Credits
    }
    private struct DeepSeekResponse: Decodable {
        struct Balance: Decodable { let currency: String; let total_balance: String; let granted_balance: String; let topped_up_balance: String }
        let is_available: Bool; let balance_infos: [Balance]
    }
}

// Never forward an entered credential to a redirect destination, even on the same host.
private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public struct GitHubFetchResult {
    public var releases: [ReleaseItem]?
    public var etag: String?
    public var retryAfter: Date
    public init(releases: [ReleaseItem]?, etag: String?, retryAfter: Date) {
        self.releases = releases; self.etag = etag; self.retryAfter = retryAfter
    }
}
public struct GitHubClient {
    private let session: URLSession
    public init(session: URLSession = BalanceClient.privateSession()) { self.session = session }
    public func fetch(_ repository: WatchedRepository, now: Date = .now) async throws -> GitHubFetchResult {
        guard let slug = WatchedRepository.parseSlug(repository.slug) else { throw ValidationError.message("Enter a public repository as owner/name.") }
        // One bounded page gives a consistent conditional cache for the latest 50 releases.
        let url = URL(string: "https://api.github.com/repos/\(slug)/releases?per_page=50&page=1")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Unifai-Local-Prototype", forHTTPHeaderField: "User-Agent")
        if let etag = repository.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ConnectorError.invalidResponse }
        if http.statusCode == 304 {
            guard repository.etag != nil else { throw ConnectorError.invalidResponse }
            return .init(releases: nil, etag: repository.etag, retryAfter: now.addingTimeInterval(1800))
        }
        if http.statusCode == 403 || http.statusCode == 429 {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            let retryHeader = http.value(forHTTPHeaderField: "Retry-After") ?? ""
            let seconds = Double(retryHeader).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? 0
            let retryDate = formatter.date(from: retryHeader) ?? now.addingTimeInterval(seconds)
            let resetSeconds = Double(http.value(forHTTPHeaderField: "X-RateLimit-Reset") ?? "").flatMap { $0.isFinite ? $0 : nil } ?? 0
            throw ConnectorError.retryAt(max(now.addingTimeInterval(1800), max(retryDate, Date(timeIntervalSince1970: resetSeconds))))
        }
        guard http.statusCode == 200 else { throw ConnectorError.unavailable(http.statusCode) }
        return .init(releases: try Self.decode(data), etag: http.value(forHTTPHeaderField: "ETag"), retryAfter: now.addingTimeInterval(1800))
    }
    public static func decode(_ data: Data) throws -> [ReleaseItem] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let rows = try decoder.decode([ReleaseResponse].self, from: data)
            guard rows.count <= 50, Set(rows.map(\.id)).count == rows.count else { throw ConnectorError.invalidResponse }
            return try rows.filter { !$0.draft }.map { item in
                guard item.html_url.scheme == "https", item.html_url.host == "github.com",
                      item.html_url.user == nil, item.html_url.password == nil,
                      item.html_url.port == nil || item.html_url.port == 443 else { throw ConnectorError.invalidResponse }
                return ReleaseItem(id: item.id, title: item.name?.isEmpty == false ? item.name! : item.tag_name,
                                   tag: item.tag_name, url: item.html_url, publishedAt: item.published_at, prerelease: item.prerelease)
            }
        } catch { throw ConnectorError.invalidResponse }
    }
    private struct ReleaseResponse: Decodable {
        let id: Int; let name: String?; let tag_name: String; let html_url: URL
        let published_at: Date?; let prerelease: Bool; let draft: Bool
    }
}

struct AnthropicCostReport: Decodable {
    struct Bucket: Decodable { let starting_at: String; let ending_at: String; let results: [Result] }
    struct Result: Decodable { let amount: String; let currency: String }
    let data: [Bucket]
}

struct OpenAICostsPage: Decodable {
    struct Bucket: Decodable {
        let start_time: Int
        let end_time: Int
        let results: [Result]
    }
    struct Result: Decodable { let amount: Amount? }
    struct Amount: Decodable { let value: Double; let currency: String }
    let data: [Bucket]
}

/// Finds command-line tools in common install locations. GUI apps do not inherit the login shell's PATH.
public enum LocalTool {
    public static func locate(_ name: String, extra: [String] = []) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "\(home)/.local/bin/\(name)", "\(home)/.npm-global/bin/\(name)",
                          "\(home)/.bun/bin/\(name)", "\(home)/.volta/bin/\(name)"] + extra
        return candidates.lazy.map { URL(fileURLWithPath: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
    /// Runs a tool and returns its standard output, or throws with the start of standard error.
    static func run(_ tool: URL, _ arguments: [String], timeout: TimeInterval = 30) throws -> (output: Data, error: String, status: Int32) {
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = tool; process.arguments = arguments
        process.environment = environment(for: tool)
        process.standardOutput = output; process.standardError = errors; process.standardInput = FileHandle.nullDevice
        try process.run()
        var collected = Data()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { Thread.sleep(forTimeInterval: 0.05) } else { collected.append(chunk) }
        }
        if process.isRunning { process.terminate(); throw ValidationError.message("\(tool.lastPathComponent) did not answer in time.") }
        collected.append(output.fileHandleForReading.readDataToEndOfFile())
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (collected, String(message.prefix(400)), process.terminationStatus)
    }
    static func environment(for tool: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = [tool.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", environment["PATH"] ?? ""].joined(separator: ":")
        return environment
    }
}

/// A short-lived `codex app-server` process speaking its JSON-RPC protocol over stdio.
final class CodexSession {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()

    init(codex: URL) throws {
        process.executableURL = codex
        process.arguments = ["app-server"]
        process.environment = LocalTool.environment(for: codex)
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        _ = try request(id: 0, method: "initialize", params: ["clientInfo": ["name": "unifai", "title": "Unifai", "version": "1"]], timeout: 25)
        try send(["method": "initialized"])
    }
    deinit { if process.isRunning { process.terminate() } }

    private func send(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    /// Reads messages until one matches, discarding others.
    private func next(until deadline: Date, matching: ([String: Any]) -> Bool) throws -> [String: Any] {
        while Date() < deadline {
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], matching(object) { return object }
            }
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { if !process.isRunning { break }; Thread.sleep(forTimeInterval: 0.05) } else { buffer.append(chunk) }
        }
        throw ValidationError.message("Codex did not answer in time. Check that codex runs in Terminal, then try again.")
    }

    func request(id: Int, method: String, params: [String: Any]? = nil, timeout: TimeInterval = 25) throws -> Data {
        var message: [String: Any] = ["id": id, "method": method]
        if let params { message["params"] = params }
        try send(message)
        let reply = try next(until: Date().addingTimeInterval(timeout)) { $0["id"] as? Int == id }
        if let error = reply["error"] as? [String: Any] {
            throw ValidationError.message("Codex returned an error: \(error["message"] as? String ?? "unknown"). Sign in again, then refresh.")
        }
        return try JSONSerialization.data(withJSONObject: reply["result"] ?? [:])
    }

    func notification(_ method: String, timeout: TimeInterval) throws -> [String: Any] {
        let message = try next(until: Date().addingTimeInterval(timeout)) { $0["method"] as? String == method && $0["id"] == nil }
        return message["params"] as? [String: Any] ?? [:]
    }
}

/// Reads the ChatGPT plan and Codex usage limits through the Codex CLI's app-server protocol.
/// Codex owns the sign-in; Unifai never sees or stores an OpenAI credential.
public struct CodexClient {
    public init() {}
    public static let source = URL(string: "https://developers.openai.com/codex/app-server")!
    public static func locate() -> URL? { LocalTool.locate("codex", extra: ["/Applications/Codex.app/Contents/Resources/codex"]) }
    static let notInstalled = ValidationError.message("Codex is not installed. Install it with brew install codex, then sign in.")

    public func fetch(now: Date = .now) async throws -> BalanceSnapshot {
        guard let codex = Self.locate() else { throw Self.notInstalled }
        let (account, limits) = try await Task.detached { () throws -> (Data, Data) in
            let session = try CodexSession(codex: codex)
            let account = try session.request(id: 1, method: "account/read", params: ["refreshToken": false])
            let limits = try session.request(id: 2, method: "account/rateLimits/read")
            return (account, limits)
        }.value
        return try Self.decode(account: account, limits: limits, now: now)
    }

    /// Runs Codex's own ChatGPT sign-in: Codex returns a browser URL and hosts the callback,
    /// then reports completion. The resulting login is stored by Codex, not by Unifai.
    public func signIn(openURL: @escaping @Sendable (URL) -> Void, timeout: TimeInterval = 600) async throws {
        guard let codex = Self.locate() else { throw Self.notInstalled }
        try await Task.detached {
            let session = try CodexSession(codex: codex)
            let started = try JSONSerialization.jsonObject(with: session.request(id: 1, method: "account/login/start", params: ["type": "chatgpt"])) as? [String: Any]
            guard let link = started?["authUrl"] as? String, let url = URL(string: link), url.scheme == "https" else {
                throw ValidationError.message("Codex did not return a sign-in link.")
            }
            openURL(url)
            let result = try session.notification("account/login/completed", timeout: timeout)
            guard result["success"] as? Bool == true else {
                throw ValidationError.message("ChatGPT sign-in did not finish\((result["error"] as? String).map { ": \($0)" } ?? ".")")
            }
        }.value
    }

    struct AccountResult: Decodable {
        struct Account: Decodable { let type: String; let planType: String? }
        let account: Account?
    }
    struct LimitsResult: Decodable {
        struct Window: Decodable { let usedPercent: Int; let windowDurationMins: Int?; let resetsAt: Int? }
        struct Credits: Decodable { let hasCredits: Bool; let unlimited: Bool; let balance: String? }
        struct Snapshot: Decodable { let planType: String?; let primary: Window?; let secondary: Window?; let credits: Credits?; let rateLimitReachedType: String? }
        let rateLimits: Snapshot
    }

    public static func decode(account accountData: Data, limits limitsData: Data, now: Date = .now) throws -> BalanceSnapshot {
        let account = try JSONDecoder().decode(AccountResult.self, from: accountData).account
        guard let account else { throw ValidationError.message("Codex is not signed in. Run codex login, then refresh.") }
        guard account.type == "chatgpt" else {
            throw ValidationError.message("Codex is signed in with an API key, which has no ChatGPT plan or Codex limits. Sign in with ChatGPT using codex login.")
        }
        let limits: LimitsResult.Snapshot
        do { limits = try JSONDecoder().decode(LimitsResult.self, from: limitsData).rateLimits }
        catch { throw ConnectorError.invalidResponse }
        let windows = [limits.primary, limits.secondary].compactMap { $0 }.map { window in
            AllowanceWindow(name: AllowanceWindow.name(forMinutes: window.windowDurationMins), usedPercent: max(0, min(100, window.usedPercent)),
                            windowMinutes: window.windowDurationMins, resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) })
        }
        var balances: [Money] = []
        var details: [BalanceDetail] = []
        if let credits = limits.credits, credits.hasCredits, !credits.unlimited, let text = credits.balance,
           let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN, value >= 0 {
            balances.append(Money(value, "CREDITS"))
        }
        if limits.credits?.unlimited == true { details.append(BalanceDetail("Codex credits", Money(0, "UNLIMITED"))) }
        let plan = (account.planType ?? limits.planType).map(Self.planName)
        return BalanceSnapshot(balances: balances, details: details, observedAt: now, source: source,
                               coverage: "Read through the Codex app on this Mac using its ChatGPT sign-in. Percentages and reset times are reported by OpenAI. Subscription payments are not included.",
                               plan: plan, allowances: windows, limitReached: limits.rateLimitReachedType != nil)
    }

    static func planName(_ raw: String) -> String {
        switch raw {
        case "plus": return "ChatGPT Plus"
        case "pro": return "ChatGPT Pro"
        case "prolite": return "ChatGPT Pro Lite"
        case "promax": return "ChatGPT Pro Max"
        case "go": return "ChatGPT Go"
        case "free": return "ChatGPT Free"
        case "team": return "ChatGPT Team"
        case "business", "self_serve_business_prolite", "self_serve_business_usage_based": return "ChatGPT Business"
        case "edu", "edu_plus", "edu_pro": return "ChatGPT Edu"
        case "unknown": return "ChatGPT"
        default: return raw.hasPrefix("enterprise") || raw == "ent26" ? "ChatGPT Enterprise" : "ChatGPT \(raw.capitalized)"
        }
    }
}

/// Reads the Claude subscription plan from Claude Code's own status command (`claude auth status --json`).
/// Anthropic offers no public interface for subscription usage limits, so none are read; Claude Code's
/// stored token is never opened.
public struct ClaudeCodeClient {
    public init() {}
    public static let source = URL(string: "https://docs.anthropic.com/en/docs/claude-code/overview")!
    public static func locate() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return LocalTool.locate("claude", extra: ["\(home)/.claude/local/claude"])
    }

    public func fetch(now: Date = .now) async throws -> BalanceSnapshot {
        guard let claude = Self.locate() else {
            throw ValidationError.message("Claude Code is not installed. Install it from claude.com/claude-code, then sign in.")
        }
        let data = try await Task.detached { try Self.run(claude, ["auth", "status", "--json"]) }.value
        return try Self.decode(data, now: now)
    }

    static func run(_ tool: URL, _ arguments: [String], timeout: TimeInterval = 20) throws -> Data {
        let process = Process(), output = Pipe()
        process.executableURL = tool; process.arguments = arguments
        process.environment = LocalTool.environment(for: tool)
        process.standardOutput = output; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { process.terminate(); throw ValidationError.message("Claude Code did not answer in time.") }
        return output.fileHandleForReading.readDataToEndOfFile()
    }

    struct Status: Decodable { let loggedIn: Bool; let authMethod: String?; let subscriptionType: String? }

    public static func decode(_ data: Data, now: Date = .now) throws -> BalanceSnapshot {
        guard let status = try? JSONDecoder().decode(Status.self, from: data) else { throw ConnectorError.invalidResponse }
        guard status.loggedIn else { throw ValidationError.message("Claude Code is not signed in. Use Sign in with Claude, then refresh.") }
        guard status.authMethod == "claude.ai" else {
            throw ValidationError.message("Claude Code is using an API key rather than a Claude subscription. Sign in with your Claude account to read the plan.")
        }
        let plan: String
        switch status.subscriptionType?.lowercased() {
        case "max": plan = "Claude Max"
        case "pro": plan = "Claude Pro"
        case "team": plan = "Claude Team"
        case "enterprise": plan = "Claude Enterprise"
        case let other?: plan = "Claude \(other.capitalized)"
        case nil: plan = "Claude"
        }
        return BalanceSnapshot(balances: [], observedAt: now, source: source,
                               coverage: "Plan read from Claude Code on this Mac (claude auth status). Anthropic does not offer subscription usage limits to other apps; run /usage in Claude Code to see them.",
                               plan: plan)
    }
}

/// Reads month-to-date Azure spend through the Azure CLI (`az rest` to the Cost Management query API).
/// The CLI owns the sign-in; Unifai never sees an Azure token. Only read-only queries are sent.
public struct AzureCostClient {
    public init() {}
    public static let source = URL(string: "https://learn.microsoft.com/en-us/rest/api/cost-management/query/usage")!
    public static func locate() -> URL? { LocalTool.locate("az") }

    struct Subscription: Decodable { let id: String; let name: String }

    public func fetch(now: Date = .now) async throws -> BalanceSnapshot {
        guard let az = Self.locate() else { throw ValidationError.message("The Azure CLI is not installed. Install it with brew install azure-cli, run az login, then refresh.") }
        let results = try await Task.detached { () throws -> [(String, Data)] in
            let list = try LocalTool.run(az, ["account", "list", "--query", "[?state=='Enabled'].{id:id,name:name}", "-o", "json", "--only-show-errors"], timeout: 60)
            guard list.status == 0 else { throw Self.cliError(list.error) }
            let subscriptions = (try? JSONDecoder().decode([Subscription].self, from: list.output)) ?? []
            guard !subscriptions.isEmpty else { throw ValidationError.message("No enabled Azure subscriptions. Run az login with the account that owns them, then refresh.") }
            let body = #"{"type":"ActualCost","timeframe":"MonthToDate","dataset":{"granularity":"None","aggregation":{"totalCost":{"name":"Cost","function":"Sum"}},"grouping":[{"type":"Dimension","name":"ServiceName"}]}}"#
            return try subscriptions.prefix(10).map { subscription in
                let url = "https://management.azure.com/subscriptions/\(subscription.id)/providers/Microsoft.CostManagement/query?api-version=2023-11-01"
                let arguments = ["rest", "--method", "post", "--url", url, "--body", body, "--only-show-errors"]
                var result = try LocalTool.run(az, arguments, timeout: 90)
                // Cost Management allows only a few queries per minute per scope; wait once and retry.
                if result.status != 0, result.error.contains("429") {
                    Thread.sleep(forTimeInterval: 12)
                    result = try LocalTool.run(az, arguments, timeout: 90)
                }
                guard result.status == 0 else { throw Self.cliError(result.error) }
                return (subscription.name, result.output)
            }
        }.value
        return try Self.decode(results, now: now)
    }

    static func cliError(_ message: String) -> Error {
        if message.localizedCaseInsensitiveContains("az login") || message.localizedCaseInsensitiveContains("expired") {
            return ValidationError.message("The Azure CLI sign-in has expired. Run az login in Terminal, then refresh.")
        }
        if message.contains("429") || message.localizedCaseInsensitiveContains("throttl") { return ConnectorError.rateLimited }
        if message.localizedCaseInsensitiveContains("AuthorizationFailed") || message.contains("403") {
            return ValidationError.message("Azure refused the cost query. The signed-in account needs Cost Management Reader (or Reader) on the subscription.")
        }
        return ValidationError.message("The Azure cost query failed. Check that az works in Terminal, then refresh.")
    }

    struct QueryResult: Decodable {
        struct Properties: Decodable {
            struct Column: Decodable { let name: String }
            let columns: [Column]
            let rows: [[CostValue]]
        }
        let properties: Properties
    }
    enum CostValue: Decodable {
        case number(Double), text(String)
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Double.self) { self = .number(value) } else { self = .text((try? container.decode(String.self)) ?? "") }
        }
        var number: Double? { if case .number(let value) = self { return value }; return nil }
        var text: String { switch self { case .number(let value): return String(value); case .text(let value): return value } }
    }

    public static func decode(_ results: [(String, Data)], now: Date = .now) throws -> BalanceSnapshot {
        var totals: [String: Decimal] = [:]
        var services: [String: [String: Decimal]] = [:]
        for (_, data) in results {
            guard let query = try? JSONDecoder().decode(QueryResult.self, from: data) else { throw ConnectorError.invalidResponse }
            let names = query.properties.columns.map(\.name)
            guard let cost = names.firstIndex(where: { $0 == "Cost" || $0 == "PreTaxCost" || $0 == "CostUSD" }),
                  let currency = names.firstIndex(of: "Currency") else { throw ConnectorError.invalidResponse }
            let service = names.firstIndex(of: "ServiceName")
            for row in query.properties.rows where row.count > max(cost, currency) {
                guard let value = row[cost].number, value.isFinite else { continue }
                let code = row[currency].text.uppercased()
                guard Money.validCurrency(code) else { throw ConnectorError.invalidResponse }
                let amount = Decimal(string: String(format: "%.6f", value)) ?? Decimal(value)
                totals[code, default: 0] += amount
                if let service { services[code, default: [:]][row[service].text, default: 0] += amount }
            }
        }
        if totals.isEmpty { totals["USD"] = 0 }
        let primary = totals.max { $0.value < $1.value }!.key
        let top = (services[primary] ?? [:]).sorted { $0.value > $1.value }.prefix(3)
            .map { BalanceDetail($0.key.isEmpty ? "Other" : $0.key, Money($0.value, primary)) }
        let count = results.count
        return BalanceSnapshot(balances: [], details: Array(top), reportedConsumption: totals.keys.sorted().map { Money(totals[$0]!, $0) },
                               observedAt: now, source: source,
                               coverage: "Month-to-date actual cost from Azure Cost Management for \(count) enabled subscription\(count == 1 ? "" : "s"), read through the Azure CLI. Costs can lag by several hours and exclude credits, invoices and taxes.",
                               consumptionPeriod: "This month")
    }
}
