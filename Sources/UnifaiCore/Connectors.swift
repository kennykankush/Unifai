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
        guard !credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ConnectorError.missingCredential }
        let endpoint: String
        switch integrationID {
        case "openrouter": endpoint = "https://openrouter.ai/api/v1/credits"
        case "deepseek": endpoint = "https://api.deepseek.com/user/balance"
        default: throw ValidationError.message("This service does not have a live balance connector yet.")
        }
        let url = URL(string: endpoint)!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ConnectorError.invalidResponse }
        switch response.statusCode {
        case 200..<300: break
        case 401, 403: throw ConnectorError.authorization
        case 429: throw ConnectorError.rateLimited
        default: throw ConnectorError.unavailable(response.statusCode)
        }
        return try Self.decode(integrationID: integrationID, data: data, source: url, now: now)
    }
    public static func decode(integrationID: String, data: Data, source: URL, now: Date = .now) throws -> BalanceSnapshot {
        do {
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
