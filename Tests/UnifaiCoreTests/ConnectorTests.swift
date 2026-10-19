import XCTest
@testable import UnifaiCore

final class StubProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: String], Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.notConnectedToInternet) }
            let (code, headers, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        config.urlCredentialStorage = nil; config.httpCookieStorage = nil
        return URLSession(configuration: config)
    }
}

final class ConnectorTests: XCTestCase {
    private let source = URL(string: "https://example.invalid/fixture")!
    override func tearDown() { StubProtocol.handler = nil; super.tearDown() }
    func testOpenRouterSeparatesCreditAndConsumptionFromCash() throws {
        let data = Data(#"{"data":{"total_credits":100.50,"total_usage":30.25}}"#.utf8)
        let snapshot = try BalanceClient.decode(integrationID: "openrouter", data: data, source: source)
        XCTAssertEqual(snapshot.balances, [Money(Decimal(string: "70.25")!, "USD")])
        XCTAssertEqual(snapshot.reportedConsumption, [Money(Decimal(string: "30.25")!, "USD")])
        XCTAssertTrue(snapshot.coverage.contains("unknown"))
        XCTAssertEqual(Ledger.paidTotals([]), [])
    }
    func testOpenRouterZeroNegativeRemainingAndMalformedResponses() throws {
        let zero = try BalanceClient.decode(integrationID: "openrouter", data: Data(#"{"data":{"total_credits":0,"total_usage":0}}"#.utf8), source: source)
        XCTAssertEqual(zero.balances, [Money(0, "USD")])
        let overdrawn = try BalanceClient.decode(integrationID: "openrouter", data: Data(#"{"data":{"total_credits":0,"total_usage":1}}"#.utf8), source: source)
        XCTAssertEqual(overdrawn.balances, [Money(-1, "USD")])
        for json in ["{}", "not-json", #"{"data":{"total_credits":-1,"total_usage":0}}"#, #"{"data":{"total_credits":1}}"#, #"{"data":{"total_credits":"oops","total_usage":0}}"#] {
            XCTAssertThrowsError(try BalanceClient.decode(integrationID: "openrouter", data: Data(json.utf8), source: source))
        }
    }
    func testDeepSeekCurrenciesAndPromotionalBalance() throws {
        let json = #"{"is_available":false,"balance_infos":[{"currency":"CNY","total_balance":"110.00","granted_balance":"10.00","topped_up_balance":"100.00"},{"currency":"USD","total_balance":"0.00","granted_balance":"0.00","topped_up_balance":"0.00"}]}"#
        let snapshot = try BalanceClient.decode(integrationID: "deepseek", data: Data(json.utf8), source: source)
        XCTAssertEqual(snapshot.balances, [Money(110, "CNY"), Money(0, "USD")])
        XCTAssertEqual(snapshot.details.count, 4)
        XCTAssertTrue(snapshot.reportedConsumption.isEmpty)
        XCTAssertTrue(snapshot.coverage.contains("unavailable"))
    }
    func testDeepSeekRejectsPartialNumericStringsAndDuplicateCurrencies() {
        for amount in ["1garbage", "NaN", "1e6", "1,000", ""] {
            let json = "{\"is_available\":true,\"balance_infos\":[{\"currency\":\"CNY\",\"total_balance\":\"\(amount)\",\"granted_balance\":\"0\",\"topped_up_balance\":\"1\"}]}"
            XCTAssertThrowsError(try BalanceClient.decode(integrationID: "deepseek", data: Data(json.utf8), source: source))
        }
        let row = #"{"currency":"USD","total_balance":"1","granted_balance":"0","topped_up_balance":"1"}"#
        let duplicate = "{\"is_available\":true,\"balance_infos\":[\(row),\(row)]}"
        XCTAssertThrowsError(try BalanceClient.decode(integrationID: "deepseek", data: Data(duplicate.utf8), source: source))
        XCTAssertThrowsError(try BalanceClient.decode(integrationID: "deepseek", data: Data(#"{"is_available":true,"balance_infos":[]}"#.utf8), source: source))
    }
    func testBalanceRequestsUseOnlyExactReadEndpoints() async throws {
        let session = StubProtocol.session(); defer { session.invalidateAndCancel() }
        StubProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/credits")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
            XCTAssertNil(request.httpBody)
            return (200, [:], Data(#"{"data":{"total_credits":100,"total_usage":30}}"#.utf8))
        }
        let snapshot = try await BalanceClient(session: session).fetch(integrationID: "openrouter", credential: "fixture-key")
        XCTAssertEqual(snapshot.balances, [Money(70, "USD")])
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/user/balance")
            return (200, [:], Data(#"{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"1","granted_balance":"0","topped_up_balance":"1"}]}"#.utf8))
        }
        _ = try await BalanceClient(session: session).fetch(integrationID: "deepseek", credential: "fixture-key")
    }
    func testHTTPFailuresAreTypedAndNeverIncludeBody() async throws {
        let session = StubProtocol.session(); defer { session.invalidateAndCancel() }
        for (status, expected) in [(401, ConnectorError.authorization), (403, .authorization), (429, .rateLimited), (500, .unavailable(500)), (302, .unavailable(302))] {
            StubProtocol.handler = { _ in (status, [:], Data("fixture-secret-response".utf8)) }
            do { _ = try await BalanceClient(session: session).fetch(integrationID: "openrouter", credential: "fixture-key"); XCTFail("Expected rejection") }
            catch { XCTAssertEqual(error as? ConnectorError, expected); XCTAssertFalse(error.localizedDescription.contains("fixture-secret")) }
        }
    }
    func testMissingCredentialAndUnsupportedProviderSendNoRequest() async {
        StubProtocol.handler = { _ in XCTFail("Must not send request"); return (500, [:], Data()) }
        for (integration, credential) in [("openrouter", ""), ("claude-api", "fixture-key")] {
            do { _ = try await BalanceClient(session: StubProtocol.session()).fetch(integrationID: integration, credential: credential); XCTFail() } catch {}
        }
    }
    func testPrivateSessionDoesNotDiscoverAmbientCredentialsOrCookies() {
        let session = BalanceClient.privateSession(); defer { session.invalidateAndCancel() }
        XCTAssertNil(session.configuration.urlCredentialStorage)
        XCTAssertNil(session.configuration.httpCookieStorage)
        XCTAssertNil(session.configuration.urlCache)
    }
    func testReleaseDecodingAndSafeLinks() throws {
        let releases = try GitHubClient.decode(Data(releaseJSON().utf8))
        XCTAssertEqual(releases.count, 1); XCTAssertEqual(releases[0].title, "v1")
        XCTAssertThrowsError(try GitHubClient.decode(Data(releaseJSON(url: "https://evil.invalid/v1").utf8)))
        XCTAssertThrowsError(try GitHubClient.decode(Data(releaseJSON(url: "http://github.com/a/b").utf8)))
        XCTAssertThrowsError(try GitHubClient.decode(Data(releaseJSON(url: "https://github.com:444/example/project/releases/tag/v1").utf8)))
        XCTAssertThrowsError(try GitHubClient.decode(Data(releaseJSON(url: "https://someone@github.com/example/project/releases/tag/v1").utf8)))
        XCTAssertEqual(try GitHubClient.decode(Data(releaseJSON(draft: true).utf8)), [])
    }
    func testGitHubUsesBoundedAnonymousConditionalGETAnd304KeepsCache() async throws {
        let session = StubProtocol.session(); defer { session.invalidateAndCancel() }
        var repo = WatchedRepository(slug: "example/project"); repo.etag = "fixture-etag"
        var requests = 0
        StubProtocol.handler = { request in
            requests += 1
            XCTAssertEqual(request.url?.query, "per_page=50&page=1")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "fixture-etag")
            return (304, [:], Data())
        }
        let now = Date()
        let result = try await GitHubClient(session: session).fetch(repo, now: now)
        XCTAssertNil(result.releases); XCTAssertEqual(result.etag, "fixture-etag")
        XCTAssertEqual(result.retryAfter, now.addingTimeInterval(1800)); XCTAssertEqual(requests, 1)
    }
    func testGitHubBackoffUsesServerReset() async throws {
        let session = StubProtocol.session(); defer { session.invalidateAndCancel() }
        let now = Date(timeIntervalSince1970: 1_000_000)
        StubProtocol.handler = { _ in (429, ["X-RateLimit-Reset": "1007200", "Retry-After": "60"], Data()) }
        do { _ = try await GitHubClient(session: session).fetch(.init(slug: "example/project"), now: now); XCTFail() }
        catch { XCTAssertEqual(error as? ConnectorError, .retryAt(now.addingTimeInterval(7200))) }
        StubProtocol.handler = { _ in (429, ["Retry-After": "Mon, 12 Jan 1970 17:46:40 GMT"], Data()) }
        do { _ = try await GitHubClient(session: session).fetch(.init(slug: "example/project"), now: now); XCTFail() }
        catch { XCTAssertEqual(error as? ConnectorError, .retryAt(Date(timeIntervalSince1970: 1_014_400))) }
    }
    func testRepositoryValidation() {
        XCTAssertEqual(WatchedRepository.parseSlug("https://github.com/example/project.git/"), "example/project")
        for input in ["a/..", "a/.", "a/b/c", "https://evil.invalid/a/b", "a/b?x=1", "a/b#fragment", "a/b%2Fsecret", "/a/b", "a//b"] { XCTAssertNil(WatchedRepository.parseSlug(input), input) }
    }
    private func releaseJSON(url: String = "https://github.com/example/project/releases/tag/v1", draft: Bool = false) -> String {
        "[{\"id\":1,\"name\":null,\"tag_name\":\"v1\",\"html_url\":\"\(url)\",\"published_at\":\"2026-10-17T00:00:00Z\",\"prerelease\":false,\"draft\":\(draft)}]"
    }
}
