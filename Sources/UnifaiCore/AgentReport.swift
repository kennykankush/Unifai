import Foundation

/// Read-only views of saved state for external agents (the MCP server).
/// Built only from `PersistentState`: no credentials, no network and no writes.
/// Measures stay separate, as in the app: remaining credit, money paid and expected renewals
/// are never added together, and currencies are never combined.
public enum AgentReport {
    public struct Amount: Codable, Equatable {
        public var amount: String
        public var currency: String
        init(_ money: Money) { amount = "\(money.amount)"; currency = money.currency }
    }

    public struct Balance: Codable, Equatable {
        public var accountID: String
        public var provider: String
        public var providerID: String
        public var label: String
        public var billingOwner: String?
        public var mode: String
        public var creditRemaining: [Amount]
        public var details: [String: Amount]
        public var reportedConsumption: [Amount]
        public var observedAt: Date?
        public var stale: Bool
        public var lastError: String?
        public var coverage: String?
        public var source: String?
        public var note: String?
    }

    public struct Payment: Codable, Equatable {
        public var description: String
        public var kind: String
        public var amount: Amount
        public var signedAmount: String
        public var paidAt: Date
        public var account: String?
        public var reference: String?
    }

    public struct Spending: Codable, Equatable {
        public var paidTotals: [Amount]
        public var since: Date?
        public var coverage: String
        public var historyConfirmedComplete: Bool
        public var payments: [Payment]
        public var note: String
    }

    public struct Renewal: Codable, Equatable {
        public var name: String
        public var expected: Amount
        public var cadence: String
        public var nextRenewal: Date
        public var daysUntil: Int
        public var overdue: Bool
        public var account: String?
    }

    public struct Overview: Codable, Equatable {
        public var generatedAt: Date
        public var balances: [Balance]
        public var paidTotals: [Amount]
        public var paymentCoverage: String
        public var upcomingRenewals: [Renewal]
        public var accountsNeedingAttention: [String]
        public var note: String
    }

    static func accountName(_ state: PersistentState, _ id: UUID?) -> String? {
        guard let id, let account = state.accounts.first(where: { $0.id == id }) else { return nil }
        return "\(Catalogue.integration(account.integrationID)?.name ?? account.integrationID) · \(account.label)"
    }

    static func matches(_ account: ConnectedAccount, _ filter: String?) -> Bool {
        guard let filter = filter?.trimmingCharacters(in: .whitespaces), !filter.isEmpty else { return true }
        let name = Catalogue.integration(account.integrationID)?.name ?? ""
        return [account.integrationID, name, account.label, account.billingScope].contains { $0.localizedCaseInsensitiveContains(filter) }
    }

    public static func balances(_ state: PersistentState, provider: String? = nil, now: Date = .now) -> [Balance] {
        state.accounts.filter { matches($0, provider) }.map { account in
            let snapshot = account.snapshot
            var note: String?
            if account.mode == .manual { note = "Manual account. No balance API; see payments and renewals." }
            else if snapshot == nil { note = "No reading yet. Refresh this account in the Unifai app." }
            else if snapshot!.isStale(at: now) { note = "Reading is older than one hour. Refresh in the Unifai app for a current value." }
            return Balance(
                accountID: account.id.uuidString,
                provider: Catalogue.integration(account.integrationID)?.name ?? account.integrationID,
                providerID: account.integrationID,
                label: account.label,
                billingOwner: account.billingScope.isEmpty ? nil : account.billingScope,
                mode: account.mode.rawValue,
                creditRemaining: snapshot?.balances.map(Amount.init) ?? [],
                details: Dictionary(snapshot?.details.map { ($0.label, Amount($0.value)) } ?? [], uniquingKeysWith: { first, _ in first }),
                reportedConsumption: snapshot?.reportedConsumption.map(Amount.init) ?? [],
                observedAt: snapshot?.observedAt,
                stale: snapshot?.isStale(at: now) ?? false,
                lastError: account.lastError,
                coverage: snapshot?.coverage,
                source: snapshot?.source.absoluteString,
                note: note)
        }
    }

    public static func spending(_ state: PersistentState, since: Date? = nil, limit: Int = 20) -> Spending {
        let records = state.payments.filter { since == nil || $0.paidAt >= since! }.sorted { $0.paidAt > $1.paidAt }
        return Spending(
            paidTotals: Ledger.paidTotals(state.payments, since: since).map(Amount.init),
            since: since ?? state.coverageStart,
            coverage: state.coverageDescription,
            historyConfirmedComplete: state.historyCoverage?.completeForPeriod == true,
            payments: records.prefix(max(0, limit)).map { record in
                Payment(description: record.description, kind: record.kind.rawValue, amount: Amount(record.money),
                        signedAmount: record.kind == .refund ? "-\(record.money.amount)" : "\(record.money.amount)",
                        paidAt: record.paidAt, account: accountName(state, record.accountID),
                        reference: record.reference.isEmpty ? nil : record.reference)
            },
            note: "Money paid from confirmed receipts the user recorded. Refunds are subtracted. Not a lifetime total unless history is confirmed complete.")
    }

    public static func renewals(_ state: PersistentState, withinDays: Int? = nil, now: Date = .now) -> [Renewal] {
        let today = Calendar.current.startOfDay(for: now)
        return state.subscriptions.sorted { $0.nextRenewal < $1.nextRenewal }.compactMap { schedule in
            let days = Calendar.current.dateComponents([.day], from: today, to: Calendar.current.startOfDay(for: schedule.nextRenewal)).day ?? 0
            if let withinDays, days > withinDays { return nil }
            return Renewal(name: schedule.name, expected: Amount(schedule.price), cadence: schedule.cadence.rawValue,
                           nextRenewal: schedule.nextRenewal, daysUntil: days, overdue: days < 0, account: accountName(state, schedule.accountID))
        }
    }

    public static func overview(_ state: PersistentState, now: Date = .now) -> Overview {
        let balances = balances(state, now: now)
        return Overview(
            generatedAt: now,
            balances: balances,
            paidTotals: Ledger.paidTotals(state.payments).map(Amount.init),
            paymentCoverage: state.coverageDescription,
            upcomingRenewals: renewals(state, withinDays: 30, now: now),
            accountsNeedingAttention: balances.filter { $0.lastError != nil || $0.stale }.map { "\($0.provider) · \($0.label)" },
            note: "Values are the last readings saved by the Unifai app. Credit remaining, money paid and expected renewals are separate measures; do not add them together or across currencies.")
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
