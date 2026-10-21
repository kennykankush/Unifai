import Foundation

/// The same arithmetic and contributing rows power the dashboard, budget and agent explanations.
public struct SpendingBreakdown: Codable, Equatable {
    public enum Status: String, Codable {
        case confirmed, estimate, automatic, accruing
        public var title: String {
            switch self {
            case .confirmed: return "Confirmed payments"
            case .estimate: return "Estimated payments"
            case .automatic: return "Scheduled payments awaiting confirmation"
            case .accruing: return "Usage not yet invoiced"
            }
        }
    }
    public struct Entry: Codable, Identifiable, Equatable {
        public var id: String
        public var accountID: UUID?
        public var providerID: String?
        public var account: String?
        public var description: String
        public var kind: String
        public var status: Status
        public var date: Date
        /// Signed: refunds are negative. Original amount/currency is never rewritten.
        public var original: Money
        public var converted: Money?
        public var conversion: String?
        public var stale: Bool
        public var lastError: String?
    }
    public struct Subtotal: Codable, Identifiable, Equatable {
        public var id: String
        public var name: String
        public var amount: Money
    }
    public var generatedAt: Date
    public var since: Date?
    public var through: Date
    public var currency: String
    public var total: Money
    public var confirmedPayments: Money
    public var estimatedPayments: Money
    public var automaticPayments: Money
    public var accruingUsage: Money
    public var complete: Bool
    public var entries: [Entry]
    public var byAccount: [Subtotal]
    public var notes: [String]
}

public extension PersistentState {
    func spendingBreakdown(in currency: String, rates: RateTable?, since: Date? = nil, through: Date? = nil,
                           includeAccruing: Bool = true, accountID: UUID? = nil, now: Date = .now) -> SpendingBreakdown {
        let target = currency.uppercased()
        let end = min(through ?? now, now)
        let monthStart = Calendar.current.dateInterval(of: .month, for: now)?.start ?? now
        var entries: [SpendingBreakdown.Entry] = []
        func append(id: String, accountID: UUID?, description: String, kind: String, status: SpendingBreakdown.Status,
                    date: Date, amount: Money, stale: Bool = false, error: String? = nil) {
            let account = accounts.first { $0.id == accountID }
            let converted = amount.currency == target ? amount : rates?.convert(amount, to: target, on: date)
            var conversion: String?
            if amount.currency != target, let rates, converted != nil,
               let from = rates.perEuro(amount.currency, on: date), let to = rates.perEuro(target, on: date) {
                let reference = rates.referenceDays(from: amount.currency, to: target, on: date)
                conversion = "1 \(amount.currency) = \(String(format: "%.6f", to / from)) \(target). ECB \(reference); approximate, rounded per entry."
            }
            entries.append(.init(id: id, accountID: accountID, providerID: account?.integrationID,
                                 account: account.map { "\(Catalogue.integration($0.integrationID)?.name ?? $0.integrationID) · \($0.label)" },
                                 description: description, kind: kind, status: status, date: date,
                                 original: amount, converted: converted, conversion: conversion, stale: stale, lastError: error))
        }
        for payment in payments where payment.paidAt <= end && (since == nil || payment.paidAt >= since!)
            && (accountID == nil || payment.accountID == accountID) {
            append(id: payment.id.uuidString, accountID: payment.accountID, description: payment.description, kind: payment.kind.rawValue,
                   status: payment.estimated == true ? .estimate : payment.scheduleID != nil ? .automatic : .confirmed,
                   date: payment.paidAt, amount: Money(payment.kind == .refund ? -payment.money.amount : payment.money.amount, payment.money.currency))
        }
        var notes = ["Confirmed, estimated and automatically recorded payments are shown separately. Refunds reduce the total. Future renewals and prepaid credit remaining are not included."]
        // A current month-to-date snapshot cannot answer a historical or partial-month interval.
        let canIncludeAccruing = end >= now && (since == nil || since! <= monthStart)
        if includeAccruing && canIncludeAccruing {
            for (account, amount) in accruingThisMonth(now: now) where accountID == nil || account.id == accountID {
                let snapshot = account.snapshot!
                append(id: "accruing-\(account.id)-\(amount.currency)", accountID: account.id,
                       description: "\(Catalogue.integration(account.integrationID)?.name ?? account.integrationID) usage this month",
                       kind: "Accruing usage", status: .accruing, date: now, amount: amount,
                       stale: snapshot.isStale(at: now), error: account.lastError)
                // The conversion uses today's rate; the observation retains its actual timestamp.
                entries[entries.count - 1].date = snapshot.observedAt
            }
        } else if includeAccruing {
            notes.append("Current accruing usage is excluded: its month-to-date reading cannot be allocated to this date range.")
        }
        let missing = entries.filter { $0.converted == nil }.count
        if missing > 0 { notes.append("\(missing) entries have no exchange rate and are excluded from the total. Their original amounts are listed.") }
        if entries.contains(where: { $0.stale || $0.lastError != nil }) {
            notes.append("Some accruing usage comes from an old or failed-refresh reading. The latest saved amount is included, but may understate current usage.")
        }
        if entries.contains(where: { $0.conversion != nil }) { notes.append("Payments use the reference rate for their payment date; accruing usage uses today's available reference rate. Your card's rate may differ.") }
        func subtotal(_ status: SpendingBreakdown.Status) -> Money {
            Money(entries.filter { $0.status == status }.compactMap(\.converted).reduce(Decimal(0)) { $0 + $1.amount }, target)
        }
        let groups = Dictionary(grouping: entries) { $0.accountID?.uuidString ?? "unassigned" }
        var byAccount: [SpendingBreakdown.Subtotal] = []
        for (id, rows) in groups {
            let sum = rows.compactMap(\.converted).reduce(Decimal(0)) { $0 + $1.amount }
            let name = rows.first?.account ?? "Unassigned payments"
            byAccount.append(.init(id: id, name: name, amount: Money(sum, target)))
        }
        byAccount.sort { a, b in
            a.amount.amount == b.amount.amount ? a.id < b.id : a.amount.amount > b.amount.amount
        }
        entries.sort { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
        return SpendingBreakdown(generatedAt: now, since: since, through: end, currency: target,
                                 total: Money(entries.compactMap(\.converted).reduce(Decimal(0)) { $0 + $1.amount }, target),
                                 confirmedPayments: subtotal(.confirmed), estimatedPayments: subtotal(.estimate),
                                 automaticPayments: subtotal(.automatic), accruingUsage: subtotal(.accruing), complete: missing == 0,
                                 entries: entries, byAccount: byAccount, notes: notes)
    }
}

private extension RateTable {
    func referenceDays(from: String, to: String, on date: Date) -> String {
        let key = Self.dayFormatter.string(from: date)
        let days = [from, to].filter { $0 != "EUR" }.compactMap { currency -> String? in
            let available = rates.keys.filter { rates[$0]?[currency] != nil }.sorted()
            return available.last(where: { $0 <= key }) ?? available.first
        }
        return Set(days).sorted().joined(separator: " / ")
    }
}
