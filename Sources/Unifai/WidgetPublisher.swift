import Foundation
import Combine
import WidgetKit
import UnifaiCore

/// Keeps the desktop widgets current: after the store settles, writes a snapshot to the shared
/// app group container and asks WidgetKit to reload. Unchanged snapshots are not rewritten.
@MainActor final class WidgetPublisher {
    private var observation: AnyCancellable?
    private weak var store: AppStore?

    init(store: AppStore) {
        self.store = store
        observation = store.objectWillChange
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.publish() }
        publish()
    }

    func publish() {
        guard let store else { return }
        if WidgetStore.save(Self.snapshot(store)) { WidgetCenter.shared.reloadAllTimelines() }
    }

    static func snapshot(_ store: AppStore, now: Date = .now) -> WidgetSnapshot {
        let state = store.state
        return WidgetSnapshot(generatedAt: now, spend: spend(store, now: now), nextRenewal: nextRenewal(state, now: now),
                              wallets: state.accounts.map { wallet($0, state: state, now: now) },
                              room: room(store, now: now), events: events(state, now: now))
    }

    private static func spend(_ store: AppStore, now: Date) -> WidgetSnapshot.Spend? {
        let state = store.state
        guard let currency = state.monthlyBudget?.currency ?? state.displayCurrency ?? SpendSeries.currencies(state.payments).first else { return nil }
        let month = state.monthToDateSpend(in: currency, rates: store.rates, now: now, includeAccruing: true)
        let accruing = state.accruingThisMonth(now: now).compactMap { item -> Decimal? in
            if item.amount.currency == currency { return item.amount.amount }
            return store.rates?.convert(item.amount, to: currency, on: now)?.amount
        }.reduce(0, +)
        // Same basis as the menu bar: combined at ECB rates when a display currency is set.
        let payments = state.displayCurrency == currency && store.rates != nil ? state.payments(in: currency, rates: store.rates!).converted : state.payments
        let calendar = Calendar.current
        let starts = (0..<6).reversed().compactMap { calendar.date(byAdding: .month, value: -$0, to: calendar.dateInterval(of: .month, for: now)?.start ?? now) }
        let months = starts.map { start -> Double in
            let end = calendar.date(byAdding: .month, value: 1, to: start) ?? now
            let total = payments.filter { $0.money.currency == currency && $0.paidAt >= start && $0.paidAt < end }
                .reduce(Decimal(0)) { $0 + ($1.kind == .refund ? -$1.money.amount : $1.money.amount) }
            return max(0, NSDecimalNumber(decimal: total).doubleValue)
        }
        return WidgetSnapshot.Spend(thisMonth: month.spent, accruing: accruing > 0 ? Money(accruing.rounded2, currency) : nil,
                                    budget: state.monthlyBudget?.currency == currency ? state.monthlyBudget : nil,
                                    months: months, monthLabels: starts.map { $0.formatted(.dateTime.month(.narrow)) }, complete: month.complete)
    }

    private static func nextRenewal(_ state: PersistentState, now: Date) -> WidgetSnapshot.Renewal? {
        let today = Calendar.current.startOfDay(for: now)
        guard let plan = state.subscriptions.filter({ $0.nextRenewal >= today }).min(by: { $0.nextRenewal < $1.nextRenewal }) else { return nil }
        let integration = state.accounts.first { $0.id == plan.accountID }?.integrationID
        return .init(name: plan.name, price: plan.price, date: plan.nextRenewal, logo: integration.flatMap(Logos.name(for:)))
    }

    /// Names short enough for a widget row.
    static func shortName(_ integrationID: String) -> String {
        switch integrationID {
        case "codex": return "Codex"
        case "chatgpt": return "ChatGPT"
        case "openrouter": return "OpenRouter"
        case "deepseek": return "DeepSeek"
        case "claude-subscription": return "Claude"
        case "claude-api": return "Claude API"
        case "openai-api": return "OpenAI API"
        case "azure-subscription": return "Azure"
        default:
            let name = Catalogue.integration(integrationID)?.name ?? integrationID
            return name.components(separatedBy: " / ").first?.replacingOccurrences(of: " account", with: "") ?? name
        }
    }

    private static func wallet(_ account: ConnectedAccount, state: PersistentState, now: Date) -> WidgetSnapshot.Wallet {
        let integration = Catalogue.integration(account.integrationID)
        let snapshot = account.snapshot
        var caption = account.mode == .manual ? "Records" : "Balance"
        var value: Money?, text: String?
        if let balance = snapshot?.balances.first {
            caption = balance.currency == "CREDITS" ? "Codex credits" : "Available"; value = balance
        } else if let spent = snapshot?.reportedConsumption.first {
            caption = integration?.billing == .payAsYouGo ? "Usage \((snapshot?.consumptionPeriod ?? "so far").lowercased())" : "Spent, \((snapshot?.consumptionPeriod ?? "reported").lowercased())"
            value = spent
        } else if let plan = snapshot?.plan {
            caption = "Plan"; text = plan
        } else if let paid = Ledger.paidTotals(state.payments.filter { $0.accountID == account.id }).first {
            caption = "Paid"; value = paid
        } else {
            text = account.mode == .manual ? "No payments" : "Refresh to read"
        }
        let windows = (snapshot?.allowances ?? []).prefix(2).map { window in
            WidgetSnapshot.Window(name: WalletCard.shortName(window), usedPercent: window.usedPercent, resetsAt: window.resetsAt)
        }
        let status: String
        if account.lastError != nil { status = "Failed" }
        else if snapshot?.limitReached == true { status = "Limit reached" }
        else if snapshot?.resetCredits?.isEmpty == false { status = "Free reset" }
        else if snapshot?.anomalies?.isEmpty == false { status = "Cost spike" }
        else if account.mode == .manual { status = "Manual" }
        else if snapshot == nil { status = "No reading" }
        else if snapshot!.isStale(at: now) { status = "Stale" }
        else { status = "Live" }
        // Two wallets from one provider are told apart by their label.
        let twin = state.accounts.filter { $0.integrationID == account.integrationID }.count > 1
        return .init(id: account.id.uuidString, name: shortName(account.integrationID) + (twin ? " · \(account.label)" : ""), label: account.label,
                     logo: Logos.name(for: account.integrationID), colors: Palette.brandHex(account.integrationID),
                     caption: caption, value: value, text: text, windows: Array(windows), status: status,
                     alert: account.lastError != nil || snapshot?.limitReached == true || snapshot?.anomalies?.isEmpty == false)
    }

    private static func room(_ store: AppStore, now: Date) -> [WidgetSnapshot.Room] {
        AgentReport.headroom(store.state, now: now, rates: store.rates).ranked.prefix(3).map { item in
            var headline = ""
            if let remaining = item.remainingPercent {
                headline = remaining <= 0 && item.creditRemaining.isEmpty ? "Used up" : remaining <= 0 ? "On credits" : "\(remaining)% left"
            } else if let credit = item.creditRemaining.first {
                headline = Money(Decimal(string: credit.amount) ?? 0, credit.currency).plainText
            } else if let spent = item.spentThisMonth.first {
                headline = Money(Decimal(string: spent.amount) ?? 0, spent.currency).plainText
            }
            return .init(name: shortName(item.providerID), label: item.label, logo: Logos.name(for: item.providerID), usable: item.usableNow, headline: headline,
                         remaining: item.remainingPercent.map { Double($0) / 100 }, nextReset: item.nextReset, freeResets: item.freeResets ?? 0)
        }
    }

    private static func events(_ state: PersistentState, now: Date) -> [WidgetSnapshot.Event] {
        let all = state.events ?? []
        let recent = all.filter { $0.important && $0.kind != .release && $0.date > now.addingTimeInterval(-7 * 86400) }
        return (recent + all.filter { !recent.contains($0) }).prefix(3)
            .map { .init(title: $0.title, kind: $0.kind.rawValue, date: $0.date, important: $0.important) }
    }
}
