import Foundation

public struct Money: Codable, Hashable, Identifiable {
    public var amount: Decimal
    public var currency: String
    public var id: String { currency }
    public init(_ amount: Decimal, _ currency: String) {
        self.amount = amount
        self.currency = currency.uppercased()
    }
    public var formatted: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 8
        return "\(currency) \(formatter.string(from: amount as NSDecimalNumber) ?? amount.description)"
    }
    public static func parseAmount(_ input: String) -> Decimal? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= 24, text.range(of: #"^[0-9]+(\.[0-9]{1,8})?$"#, options: .regularExpression) != nil,
              let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")),
              !value.isNaN else { return nil }
        return value
    }
    public static func validCurrency(_ input: String) -> Bool {
        Locale.commonISOCurrencyCodes.contains(input.uppercased())
    }
}

public enum ConnectionMode: String, Codable { case live, manual }

public struct BalanceDetail: Codable, Hashable {
    public var label: String
    public var value: Money
    public init(_ label: String, _ value: Money) { self.label = label; self.value = value }
}

/// A usage allowance that resets on a schedule, such as Codex's 5-hour and weekly windows.
public struct AllowanceWindow: Codable, Hashable, Identifiable {
    public var name: String
    public var usedPercent: Int
    public var windowMinutes: Int?
    public var resetsAt: Date?
    public var id: String { name }
    public init(name: String, usedPercent: Int, windowMinutes: Int? = nil, resetsAt: Date? = nil) {
        self.name = name; self.usedPercent = usedPercent; self.windowMinutes = windowMinutes; self.resetsAt = resetsAt
    }
    public static func name(forMinutes minutes: Int?) -> String {
        switch minutes {
        case 300: return "5-hour window"
        case 10080: return "Weekly window"
        case let value? where value % 1440 == 0: return "\(value / 1440)-day window"
        case let value? where value % 60 == 0: return "\(value / 60)-hour window"
        case let value?: return "\(value)-minute window"
        default: return "Usage window"
        }
    }
}

public struct BalanceSnapshot: Codable, Hashable {
    public var balances: [Money]
    public var details: [BalanceDetail]
    public var reportedConsumption: [Money]
    public var observedAt: Date
    public var source: URL
    public var coverage: String
    // Optional additions keep earlier schema-1 snapshots readable.
    public var plan: String?
    public var allowances: [AllowanceWindow]?
    public var limitReached: Bool?
    public var consumptionPeriod: String?
    public init(balances: [Money], details: [BalanceDetail] = [], reportedConsumption: [Money] = [], observedAt: Date = .now, source: URL, coverage: String,
                plan: String? = nil, allowances: [AllowanceWindow]? = nil, limitReached: Bool? = nil, consumptionPeriod: String? = nil) {
        self.balances = balances; self.details = details; self.reportedConsumption = reportedConsumption
        self.observedAt = observedAt; self.source = source; self.coverage = coverage
        self.plan = plan; self.allowances = allowances; self.limitReached = limitReached; self.consumptionPeriod = consumptionPeriod
    }
    public func isStale(at date: Date = .now) -> Bool { date.timeIntervalSince(observedAt) > 3600 }
}

public struct ConnectedAccount: Codable, Identifiable, Hashable {
    public var id: UUID
    public var integrationID: String
    public var label: String
    public var billingScope: String
    public var mode: ConnectionMode
    public var createdAt: Date
    public var snapshot: BalanceSnapshot?
    public var lastAttempt: Date?
    public var lastError: String?
    public init(id: UUID = UUID(), integrationID: String, label: String, billingScope: String = "", mode: ConnectionMode) {
        self.id = id; self.integrationID = integrationID; self.label = label
        self.billingScope = billingScope; self.mode = mode; self.createdAt = .now
    }
}

public enum PaymentKind: String, Codable, CaseIterable, Identifiable {
    case subscription = "Subscription payment"
    case topUp = "Credit top-up"
    case usageCharge = "Settled usage charge"
    case refund = "Refund"
    public var id: String { rawValue }
}

public struct PaymentRecord: Codable, Identifiable, Hashable {
    public var id: UUID
    public var accountID: UUID?
    public var description: String
    public var kind: PaymentKind
    public var money: Money
    public var paidAt: Date
    public var reference: String
    public var createdAt: Date
    public init(id: UUID = UUID(), accountID: UUID? = nil, description: String, kind: PaymentKind, money: Money, paidAt: Date, reference: String = "") {
        self.id = id; self.accountID = accountID; self.description = description; self.kind = kind
        self.money = money; self.paidAt = paidAt; self.reference = reference; self.createdAt = .now
    }
}

public enum BillingCadence: String, Codable, CaseIterable, Identifiable {
    case monthly = "Monthly", yearly = "Yearly"
    public var id: String { rawValue }
}

public struct SubscriptionSchedule: Codable, Identifiable, Hashable {
    public var id: UUID
    public var accountID: UUID?
    public var name: String
    public var price: Money
    public var cadence: BillingCadence
    public var nextRenewal: Date
    public init(id: UUID = UUID(), accountID: UUID? = nil, name: String, price: Money, cadence: BillingCadence, nextRenewal: Date) {
        self.id = id; self.accountID = accountID; self.name = name; self.price = price
        self.cadence = cadence; self.nextRenewal = nextRenewal
    }
}

public enum Ledger {
    public static func paidTotals(_ records: [PaymentRecord], since start: Date? = nil, through end: Date = .now) -> [Money] {
        var amounts: [String: Decimal] = [:]
        for record in records where record.paidAt <= end && (start == nil || record.paidAt >= start!) {
            amounts[record.money.currency, default: 0] += record.kind == .refund ? -record.money.amount : record.money.amount
        }
        return amounts.keys.sorted().map { Money(amounts[$0]!, $0) }
    }
    public static func validate(_ record: PaymentRecord, existing: [PaymentRecord], now: Date = .now) throws {
        guard record.money.amount > 0, !record.money.amount.isNaN, Money.validCurrency(record.money.currency) else {
            throw ValidationError.message("Enter a positive amount and a supported currency code.")
        }
        guard record.paidAt <= now else { throw ValidationError.message("A completed payment cannot have a future date. Add a renewal schedule instead.") }
        guard !record.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ValidationError.message("Give this payment a name.") }
        let reference = record.reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if !reference.isEmpty && existing.contains(where: {
            $0.id != record.id && $0.accountID == record.accountID && $0.reference.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(reference) == .orderedSame
        }) { throw ValidationError.message("This payment reference already exists for that account.") }
    }
    public static func validate(_ schedule: SubscriptionSchedule) throws {
        guard schedule.price.amount > 0, !schedule.price.amount.isNaN, Money.validCurrency(schedule.price.currency),
              !schedule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.message("Enter a subscription name, positive amount and supported currency.")
        }
    }
}

public enum ValidationError: LocalizedError, Equatable {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

public struct ReleaseItem: Codable, Identifiable, Hashable {
    public var id: Int
    public var title: String
    public var tag: String
    public var url: URL
    public var publishedAt: Date?
    public var prerelease: Bool
    public init(id: Int, title: String, tag: String, url: URL, publishedAt: Date?, prerelease: Bool) {
        self.id = id; self.title = title; self.tag = tag; self.url = url; self.publishedAt = publishedAt; self.prerelease = prerelease
    }
}

public struct WatchedRepository: Codable, Identifiable, Hashable {
    public var id: UUID
    public var slug: String
    public var releases: [ReleaseItem]
    public var includePrereleases: Bool
    public var lastAttempt: Date?
    public var lastSuccess: Date?
    public var lastError: String?
    public var etag: String?
    public var nextAllowedRefresh: Date?
    public init(id: UUID = UUID(), slug: String, includePrereleases: Bool = false) {
        self.id = id; self.slug = slug; self.releases = []; self.includePrereleases = includePrereleases
    }
    public static func parseSlug(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("https://github.com/") { text.removeFirst("https://github.com/".count) }
        if text.hasSuffix("/") { text.removeLast() }
        if text.hasSuffix(".git") { text.removeLast(4) }
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts[0].range(of: #"^[A-Za-z0-9][A-Za-z0-9-]{0,38}$"#, options: .regularExpression) != nil,
              parts[1].range(of: #"^[A-Za-z0-9_.-]{1,100}$"#, options: .regularExpression) != nil,
              parts[1] != ".", parts[1] != ".." else { return nil }
        return text
    }
}

public struct PersistentState: Codable, Equatable {
    public var schemaVersion: Int = 1
    public var accounts: [ConnectedAccount] = []
    public var payments: [PaymentRecord] = []
    public var subscriptions: [SubscriptionSchedule] = []
    public var repositories: [WatchedRepository] = []
    // Optional additions preserve the original schema-1 scaffold files.
    public var historyCoverage: HistoryCoverage?
    public var githubRequests: [Date]?
    public var githubBackoffUntil: Date?
    public init() {}
}

public struct HistoryCoverage: Codable, Equatable {
    public var start: Date
    public var completeForPeriod: Bool
    public init(start: Date, completeForPeriod: Bool) { self.start = start; self.completeForPeriod = completeForPeriod }
}

public extension PersistentState {
    var coverageStart: Date? { historyCoverage?.start ?? payments.map(\.paidAt).min() }
    var coverageDescription: String {
        guard let start = coverageStart else { return "No payment history recorded" }
        let status = historyCoverage?.completeForPeriod == true ? "Confirmed complete for this period" : "Partial history"
        return "Recorded since \(start.formatted(date: .abbreviated, time: .omitted)) · \(status)"
    }
    func visibleReleases(for repository: WatchedRepository) -> [ReleaseItem] {
        repository.releases.filter { repository.includePrereleases || !$0.prerelease }
    }
}
