import SwiftUI
import AppKit
import UnifaiCore

struct SpendingBreakdownView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State var monthOnly: Bool
    let currency: String

    private var report: SpendingBreakdown {
        let start = monthOnly ? Calendar.current.dateInterval(of: .month, for: .now)?.start : nil
        return store.state.spendingBreakdown(in: currency, rates: store.state.displayCurrency == nil ? nil : store.rates, since: start)
    }

    var body: some View {
        let breakdown = report
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Spending breakdown").font(.system(size: 22, weight: .bold))
                    Text("The payments and usage behind your total").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(PillButtonStyle(compact: true))
            }.padding(24)
            Picker("Period", selection: $monthOnly) {
                Text("This month").tag(true)
                Text("All recorded history").tag(false)
            }.pickerStyle(.segmented).padding(.horizontal, 24).padding(.bottom, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 12) {
                        MoneyText(money: breakdown.total, size: 34, weight: .heavy)
                        summary("Confirmed payments", breakdown.confirmedPayments)
                        if breakdown.estimatedPayments.amount != 0 { summary("Estimates awaiting confirmation", breakdown.estimatedPayments) }
                        if breakdown.automaticPayments.amount != 0 { summary("Automatic renewals awaiting confirmation", breakdown.automaticPayments) }
                        if breakdown.accruingUsage.amount != 0 { summary("Usage not yet invoiced", breakdown.accruingUsage) }
                        Text("Future renewals and credit remaining are excluded.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }.surface(padding: 20, radius: 18)
                    if !breakdown.complete {
                        InlineNotice(text: "This total is incomplete. Entries without an exchange rate are listed below but are not added.")
                    }
                    if breakdown.entries.isEmpty {
                        Text("No payments or current usage in this period.").foregroundStyle(.secondary).padding(.vertical, 30)
                    } else {
                        Text("Included entries").font(.system(size: 14, weight: .semibold))
                        LazyVStack(spacing: 14) {
                            ForEach(breakdown.entries) { entry in entryRow(entry) }
                        }
                    }
                    ForEach(breakdown.notes, id: \.self) { note in
                        Text(note).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(.horizontal, 24).padding(.bottom, 24)
            }
        }
        .frame(width: 740, height: 580)
        .background(Palette.canvas)
        .background(SheetChrome())
    }

    private func summary(_ title: String, _ value: Money) -> some View {
        HStack {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            MoneyText(money: value, size: 13, weight: .semibold)
        }
    }

    private func entryRow(_ entry: SpendingBreakdown.Entry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 14) {
                LogoCircle(integrationID: entry.providerID, size: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.description).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    Text([entry.account, entry.date.formatted(date: .abbreviated, time: .omitted)].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(entry.status.title).font(.system(size: 10, weight: .medium))
                        .foregroundStyle(entry.status == .confirmed ? Color.secondary : Palette.warning)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 4) {
                    MoneyText(money: entry.converted ?? entry.original, size: 14, weight: .semibold)
                    if entry.converted == nil { Text("Not added").font(.system(size: 10)).foregroundStyle(Palette.warning) }
                    else if entry.original.currency != currency {
                        Text(entry.original.plainText).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }.fixedSize()
            }
            if let conversion = entry.conversion {
                Text(conversion).font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled).padding(.leading, 44)
            }
            if entry.stale || entry.lastError != nil {
                Text("Using the last saved reading. Refresh this wallet to check current usage.")
                    .font(.system(size: 11)).foregroundStyle(Palette.warning).padding(.leading, 44)
            }
        }.padding(14).background(RoundedRectangle(cornerRadius: 14).fill(Palette.surface))
    }
}

struct BackupsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var copies: [StateRepository.Backup] = []
    @State private var selected: StateRepository.Backup?
    @State private var error: String?
    var onRestore: (() -> Void)?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Local backups").font(.system(size: 22, weight: .bold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Unifai keeps 30 recent versions and 14 daily checkpoints before saving changes. These copies stay on this Mac and contain no API keys.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error { InlineNotice(text: error) }
            ScrollView {
                LazyVStack(spacing: 10) {
                    if copies.isEmpty {
                        Text("No backups yet. A backup is created when existing saved data changes.").foregroundStyle(.secondary).padding(.vertical, 32)
                    }
                    ForEach(copies) { backup in
                        HStack(spacing: 14) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(backup.savedAt.formatted(date: .abbreviated, time: .standard)).font(.system(size: 13, weight: .semibold))
                                Text("\(backup.payments) payments · \(backup.accounts) wallets\(backup.daily ? " · Daily checkpoint" : "")")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Restore…") { selected = backup }
                                .accessibilityLabel("Restore backup from \(backup.savedAt.formatted())")
                        }.padding(14).background(RoundedRectangle(cornerRadius: 14).fill(Palette.surface))
                    }
                }
            }
            Text("Restoring replaces saved records and settings. The displaced file is preserved, and Keychain credentials stay unchanged.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Show Backup Folder") { NSWorkspace.shared.open(store.repository.backupDirectory) }.disabled(copies.isEmpty)
        }
        .padding(24).frame(width: 650, height: 540).background(Palette.canvas).background(SheetChrome())
        .onAppear(perform: reload)
        .alert("Restore this backup?", isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
            Button("Cancel", role: .cancel) { selected = nil }
            Button("Restore Backup", role: .destructive) {
                guard let backup = selected else { return }
                do { try store.restoreBackup(backup.id); dismiss(); onRestore?() }
                catch { self.error = error.localizedDescription }
                selected = nil
            }
        } message: {
            Text("This restores \(selected?.payments ?? 0) payments and \(selected?.accounts ?? 0) wallets. Your current data file will be preserved in the backup folder.")
        }
    }
    private func reload() {
        do { copies = try store.repository.backups() }
        catch { self.error = error.localizedDescription }
    }
}
