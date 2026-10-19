import SwiftUI
import AppKit
import UnifaiCore

enum Destination: String, CaseIterable, Identifiable {
    case today = "Today", accounts = "Accounts", payments = "Payments", subscriptions = "Subscriptions", releases = "Releases", catalogue = "Catalogue"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .today: return "Overview"
        case .accounts: return "Wallets"
        default: return rawValue
        }
    }
    var symbol: String {
        switch self {
        case .today: return "square.grid.2x2.fill"
        case .accounts: return "wallet.pass.fill"
        case .payments: return "arrow.left.arrow.right"
        case .subscriptions: return "calendar"
        case .releases: return "shippingbox.fill"
        case .catalogue: return "square.stack.3d.up.fill"
        }
    }
}

enum Editor: Identifiable {
    case account(Integration, ConnectedAccount?), payment(PaymentRecord?), subscription(SubscriptionSchedule?), repository, coverage
    var id: String {
        switch self {
        case .account(let integration, let account): return "account-\(integration.id)-\(account?.id.uuidString ?? "new")"
        case .payment(let record): return "payment-\(record?.id.uuidString ?? "new")"
        case .subscription(let record): return "subscription-\(record?.id.uuidString ?? "new")"
        case .repository: return "repository"
        case .coverage: return "coverage"
        }
    }
}

struct MainView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.openWindow) private var openWindow
    let fixtureMode: Bool
    @State private var destination: Destination = AppRuntime.initialDestination ?? .today
    @State private var search = ""
    @State private var editor: Editor?
    @State private var category: IntegrationCategory?
    @State private var removal: Removal?
    @State private var chartCurrency = ""
    @State private var chartMode = "Cumulative"
    @State private var copiedSetup = false
    @State private var signingIn: Set<UUID> = []
    @FocusState private var searchFocused: Bool
    @State private var searchActive = false
    @Namespace private var navNamespace
    struct Removal: Identifiable { let id = UUID(); let title: String; let action: () throws -> Void }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let error = store.loadFailure { InlineNotice(text: error).padding(.bottom, 18) }
                    page
                    footer
                }
                .padding(.horizontal, 40).padding(.top, 30).padding(.bottom, 28)
                .frame(maxWidth: 1240, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.top)
            .id(destination)
            .transition(.identity)
            .background(Palette.canvas)
        }
        .background(Palette.canvas)
        .background(WindowConfigurator(headerHeight: 64))
        .ignoresSafeArea(.container, edges: .top)
        .onChange(of: destination) { _, _ in search = "" }
        .onAppear {
            AppRuntime.openMain = { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
            AppRuntime.scheduleTestClick()
        }
        .sheet(item: $editor) { item in
            switch item {
            case .account(let integration, let account): AccountEditor(integration: integration, account: account)
            case .payment(let record): PaymentEditor(record: record)
            case .subscription(let schedule): SubscriptionEditor(schedule: schedule)
            case .repository: RepositoryEditor()
            case .coverage: CoverageEditor()
            }
        }
        .alert("Unifai", isPresented: Binding(get: { store.notice != nil }, set: { if !$0 { store.notice = nil } })) {
            Button("OK", role: .cancel) { store.notice = nil }
        } message: { Text(store.notice ?? "") }
        .alert(item: $removal) { item in
            Alert(title: Text(item.title), message: Text("This removes the local record from Unifai."),
                  primaryButton: .destructive(Text("Remove"), action: { perform(item.action) }), secondaryButton: .cancel())
        }
    }

    @ViewBuilder private var page: some View {
        switch destination {
        case .today: overview
        case .accounts: wallets
        case .payments: payments
        case .subscriptions: subscriptions
        case .catalogue: catalogue
        case .releases: releases
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        ViewThatFits(in: .horizontal) {
            topBarContent(compact: false)
            topBarContent(compact: true)
        }
        .padding(.leading, 92).padding(.trailing, 20)
        .frame(height: 64)
        .background(WindowDragArea())
        .background(Palette.bar)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.border.opacity(0.7)).frame(height: 1) }
    }

    private func topBarContent(compact: Bool) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 10) {
                AppMark(size: 30)
                Text("Unifai.").font(.system(size: 19, weight: .semibold)).tracking(-0.6)
                if fixtureMode { Chip(text: "Demo", tint: Palette.warning, symbol: "testtube.2") }
                else if AppRuntime.channel == "dev" { Chip(text: "Dev", tint: Palette.accentInk, symbol: "hammer.fill") }
            }
            .fixedSize()
            Spacer(minLength: compact ? 12 : 24)
            HStack(spacing: compact ? 0 : 4) {
                ForEach(Destination.allCases) { navItem($0, compact: compact) }
            }
            .fixedSize()
            Spacer(minLength: compact ? 12 : 24)
            HStack(spacing: 10) {
                agentButton(compact: compact)
                primaryAction
            }
            .fixedSize()
        }
    }

    private func navItem(_ item: Destination, compact: Bool) -> some View {
        let selected = destination == item
        let signal = navSignal(item)
        return Button { withAnimation(.snappy(duration: 0.28)) { destination = item } } label: {
            HStack(spacing: 6) {
                Text(item.title)
                    .font(.system(size: 14, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.72))
                if let signal {
                    Circle().fill(signal).frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, compact ? 12 : 18).frame(height: 40)
            .background {
                if selected {
                    Capsule().fill(Color.primary.opacity(0.1))
                        .overlay(Capsule().strokeBorder(LinearGradient(colors: [Color.primary.opacity(0.1), .clear], startPoint: .top, endPoint: .bottom)))
                        .matchedGeometryEffect(id: "nav", in: navNamespace)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title + (signal == nil ? "" : ", needs attention"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// A small dot only where something needs action: failed or stale wallets, renewals within a week.
    private func navSignal(_ item: Destination) -> Color? {
        switch item {
        case .accounts: return store.state.accounts.contains(where: needsAttention) ? Palette.warning : nil
        case .subscriptions: return store.state.subscriptions.contains { daysUntil($0.nextRenewal) <= 7 } ? Palette.lime : nil
        default: return nil
        }
    }

    /// Setup line for the MCP server shipped inside this app bundle (or a local release build of it).
    private var mcpCommand: String? {
        let bundled = Bundle.main.url(forAuxiliaryExecutable: "unifai-mcp")
        let local = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("release/unifai-mcp")
        guard let binary = [bundled, local].compactMap({ $0 }).first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { return nil }
        let defaultDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Unifai", isDirectory: true)
        let directory = store.repository.directory.standardizedFileURL
        let extra = directory == defaultDirectory.standardizedFileURL ? "" : " --data-directory \"\(directory.path)\""
        let name = AppRuntime.channel == "release" ? "unifai" : "unifai-\(AppRuntime.channel)"
        return "claude mcp add --scope user \(name) -- \"\(binary.path)\"\(extra)"
    }

    private func agentButton(compact: Bool) -> some View {
        Button {
            guard let command = mcpCommand else {
                store.notice = "Build the MCP server first with scripts/build-mcp.sh, then copy the setup command from here."
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            withAnimation { copiedSetup = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation { copiedSetup = false } }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: copiedSetup ? "checkmark" : "sparkles").font(.system(size: 12, weight: .bold))
                if !compact { Text(copiedSetup ? "Command copied" : "Agent access") }
            }
        }
        .buttonStyle(PillButtonStyle(kind: .white))
        .accessibilityLabel(copiedSetup ? "Command copied" : "Agent access")
        .help(mcpCommand.map { "Copy the MCP setup command so coding agents can read balances and spend (read-only):\n\($0)" } ?? "Build the MCP server with scripts/build-mcp.sh")
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: fixtureMode ? "testtube.2" : "lock.fill")
            Text(fixtureMode ? "Synthetic workspace. Network requests are disabled and no real account data is shown." : "Stored on this Mac. Credentials stay in Keychain.")
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(fixtureMode ? AnyShapeStyle(Palette.warning.opacity(0.9)) : AnyShapeStyle(.tertiary))
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            // Kept out of the key-view loop until requested, so macOS cannot auto-focus it on window activation.
            TextField(searchPrompt, text: $search).textFieldStyle(.plain).font(.system(size: 13)).focused($searchFocused)
                .disabled(!searchActive && search.isEmpty)
            if search.isEmpty {
                Text("⌘F").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            } else {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14).frame(width: 240, height: 38)
        .background(Capsule().fill(Palette.surface))
        .overlay(Capsule().strokeBorder(searchFocused ? Palette.accent.opacity(0.7) : Palette.border, lineWidth: searchFocused ? 1.5 : 1))
        .overlay {
            if !searchActive && search.isEmpty {
                Color.clear.contentShape(Capsule()).onTapGesture(perform: activateSearch)
            }
        }
        .background { Button("", action: activateSearch).keyboardShortcut("f").hidden() }
        .onChange(of: searchFocused) { _, focused in if !focused && search.isEmpty { searchActive = false } }
    }

    private func activateSearch() {
        searchActive = true
        DispatchQueue.main.async { searchFocused = true }
    }

    // MARK: Helpers

    private var searchPrompt: String {
        switch destination {
        case .catalogue: return "Search services"
        case .releases: return "Search releases"
        case .payments: return "Search payments"
        default: return "Search"
        }
    }
    private func matches(_ strings: String...) -> Bool { search.isEmpty || strings.contains { $0.localizedCaseInsensitiveContains(search) } }
    private func perform(_ action: () throws -> Void) { do { try action() } catch { store.notice = error.localizedDescription } }
    private func integrationName(_ account: ConnectedAccount) -> String { Catalogue.integration(account.integrationID)?.name ?? account.integrationID }
    private func accountName(_ id: UUID?) -> String {
        guard let id, let account = store.state.accounts.first(where: { $0.id == id }) else { return "Unassigned" }
        return "\(integrationName(account)) · \(account.label)"
    }
    private func account(_ id: UUID?) -> ConnectedAccount? { id.flatMap { id in store.state.accounts.first { $0.id == id } } }
    private func needsAttention(_ account: ConnectedAccount) -> Bool { account.lastError != nil || account.snapshot?.isStale() == true }
    private func daysUntil(_ date: Date) -> Int {
        Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: .now), to: Calendar.current.startOfDay(for: date)).day ?? 0
    }
    private func relativeDays(_ days: Int) -> String {
        switch days {
        case ..<0: return "\(-days) day\(days == -1 ? "" : "s") overdue"
        case 0: return "Due today"
        case 1: return "Tomorrow"
        default: return "In \(days) days"
        }
    }
    private func paidTotals(for account: ConnectedAccount) -> [Money] { Ledger.paidTotals(store.state.payments.filter { $0.accountID == account.id }) }
    private var chartCurrencies: [String] { SpendSeries.currencies(store.state.payments) }
    private var activeCurrency: String { chartCurrencies.contains(chartCurrency) ? chartCurrency : (chartCurrencies.first ?? "USD") }
    private var currencyBinding: Binding<String> { Binding(get: { activeCurrency }, set: { chartCurrency = $0 }) }

    private func refreshAll() {
        let ids = store.state.accounts.filter { $0.mode == .live && ($0.lastAttempt.map { Date.now.timeIntervalSince($0) >= 60 } ?? true) }.map(\.id)
        if ids.isEmpty { store.notice = "Balances were refreshed less than a minute ago. Try again shortly."; return }
        Task { for id in ids { await store.refreshAccount(id) } }
    }

    private func pageHeader(_ title: String, _ subtitle: String, chip: Chip? = nil) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Text(title).font(.system(size: 30, weight: .bold)).tracking(-0.9)
                    if let chip { chip }
                }
                Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            searchField
        }
        .padding(.bottom, 26)
    }

    @ViewBuilder private var primaryAction: some View {
        switch destination {
        case .today, .accounts:
            Button { destination = .catalogue } label: { Label("Add Wallet", systemImage: "plus") }
                .buttonStyle(PillButtonStyle(kind: .lime)).keyboardShortcut("n")
        case .payments:
            Button { editor = .payment(nil) } label: { Label("Add Payment", systemImage: "plus") }
                .buttonStyle(PillButtonStyle(kind: .lime)).keyboardShortcut("n")
        case .subscriptions:
            Button { editor = .subscription(nil) } label: { Label("Add Subscription", systemImage: "plus") }
                .buttonStyle(PillButtonStyle(kind: .lime)).keyboardShortcut("n")
        case .releases:
            Button { editor = .repository } label: { Label("Follow Repository", systemImage: "plus") }
                .buttonStyle(PillButtonStyle(kind: .lime)).keyboardShortcut("n")
        case .catalogue:
            EmptyView()
        }
    }

    /// Unifai's own empty state. Replaces ContentUnavailableView, whose hit area covered
    /// buttons placed below it, so the optional action lives inside the component instead.
    private func emptyState(_ title: String, _ description: String, _ symbol: String,
                            action: String? = nil, perform: @escaping () -> Void = {}) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 22, weight: .semibold)).foregroundStyle(Palette.accentInk)
                .frame(width: 56, height: 56)
                .background(Circle().fill(Palette.accent.opacity(0.14)))
                .overlay(Circle().strokeBorder(Palette.accent.opacity(0.2)))
            Text(title).font(.system(size: 17, weight: .bold)).tracking(-0.2)
            Text(description).font(.system(size: 13)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 420).fixedSize(horizontal: false, vertical: true)
            if let action {
                Button(action, action: perform).buttonStyle(PillButtonStyle(kind: .primary)).padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func moreMenu<Content: View>(_ label: String, onColor: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        Menu(content: content) {
            Image(systemName: "ellipsis").font(.system(size: 12, weight: .bold))
                .foregroundStyle(onColor ? Color.white : Color.secondary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(onColor ? Color.white.opacity(0.18) : Palette.raised.opacity(0.6)))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel(label)
    }

    // MARK: Overview

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: return "Good morning"
        case 12..<18: return "Good afternoon"
        default: return "Good evening"
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 26) {
            pageHeader(greeting, Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()) + ". Here is where your AI money stands.")
                .padding(.bottom, -26)
            if store.state.accounts.isEmpty && store.state.payments.isEmpty && store.state.repositories.isEmpty {
                emptyState("Start with your wallets", "Connect OpenRouter or DeepSeek, record subscription payments, and follow public GitHub releases.", "wallet.pass",
                           action: "Browse Catalogue") { destination = .catalogue }
                    .surface()
            }
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 16) {
                    heroCard
                    quickActions
                }
                VStack(spacing: 18) {
                    walletsTile
                    renewalTile
                }
                .frame(width: 300)
            }
            if !store.state.accounts.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeading(title: "My Wallets", subtitle: "\(store.state.accounts.count)") { SeeAllButton { destination = .accounts } }
                    ScrollView(.horizontal) {
                        HStack(spacing: 16) {
                            ForEach(store.state.accounts.filter { matches($0.label, integrationName($0)) }) { account in
                                WalletCard(account: account, paid: paidTotals(for: account))
                                    .frame(width: 290)
                                    .onTapGesture { destination = .accounts }
                                    .contextMenu { walletMenuItems(account) }
                            }
                            addWalletCard
                        }
                        .padding(.vertical, 14).padding(.horizontal, 2)
                    }
                    .scrollIndicators(.never)
                    .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.9), .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing))
                    .padding(.vertical, -14)
                }
            }
            HStack(alignment: .top, spacing: 18) {
                transactionsPanel
                spendingPanel.frame(width: 300)
            }
            if !recentReleases(limit: 1).isEmpty { releasesStrip }
        }
    }

    private var heroCard: some View {
        let currency = activeCurrency
        let total = Ledger.paidTotals(store.state.payments).first { $0.currency == currency }
        let month = SpendSeries.paidThisMonth(store.state.payments, currency: currency)
        let points = SpendSeries.cumulative(store.state.payments, currency: currency, start: store.state.coverageStart)
        return ZStack(alignment: .topLeading) {
            MeshBackdrop(colors: Palette.hero)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    HStack(spacing: 7) {
                        Image(systemName: "creditcard.fill").font(.system(size: 12, weight: .bold))
                        Text("Total paid for AI").font(.system(size: 14, weight: .semibold))
                    }
                    .opacity(0.9)
                    Spacer()
                    if chartCurrencies.count > 1 { PillMenu(options: chartCurrencies, selection: currencyBinding, onColor: true) { $0 } }
                    else { GlassChip(text: currency) }
                }
                Spacer(minLength: 10)
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        if let total { MoneyText(money: total, size: 46, weight: .heavy) }
                        else { Text("Nothing yet").font(.system(size: 38, weight: .heavy)).tracking(-1) }
                        HStack(spacing: 8) {
                            if month > 0 {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .heavy))
                                    Text("\(Money(Decimal(month), currency).amountText) this month").font(.system(size: 12, weight: .bold)).monospacedDigit()
                                }
                                .foregroundStyle(Palette.hex(0x15161B))
                                .padding(.horizontal, 9).frame(height: 24)
                                .background(Capsule().fill(Palette.lime))
                            }
                            Text(store.state.coverageDescription).font(.system(size: 12, weight: .medium)).opacity(0.75).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 16)
                    if points.count > 2 { Sparkline(points: points).frame(width: 200, height: 84) }
                }
            }
            .padding(24)
        }
        .foregroundStyle(.white)
        .frame(height: 232)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Color.white.opacity(0.14)))
        .shadow(color: Palette.hero[1].opacity(0.35), radius: 24, y: 12)
    }

    private var quickActions: some View {
        HStack(spacing: 10) {
            Button { editor = .payment(nil) } label: { Label("Add Payment", systemImage: "plus") }.buttonStyle(PillButtonStyle())
            Button(action: refreshAll) { Label("Refresh Balances", systemImage: "arrow.clockwise") }
                .buttonStyle(PillButtonStyle())
                .disabled(store.loadFailure != nil || !store.state.accounts.contains { $0.mode == .live } || !store.refreshingAccounts.isEmpty)
            Button { editor = .subscription(nil) } label: { Label("Add Renewal", systemImage: "calendar.badge.plus") }.buttonStyle(PillButtonStyle())
            Button { editor = .repository } label: { Label("Follow Repo", systemImage: "shippingbox") }.buttonStyle(PillButtonStyle())
            if !store.refreshingAccounts.isEmpty { ProgressView().controlSize(.small) }
        }
    }

    private var walletsTile: some View {
        let attention = store.state.accounts.filter(needsAttention).count
        let live = store.state.accounts.filter { $0.mode == .live && $0.snapshot != nil && !needsAttention($0) }.count
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Wallets").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                LogoStack(ids: Array(Set(store.state.accounts.map(\.integrationID))).sorted(), size: 26)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(store.state.accounts.count)").font(.system(size: 34, weight: .heavy)).tracking(-1).contentTransition(.numericText())
                Text("connected").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                if attention > 0 { Chip(text: "\(attention) need attention", tint: Palette.warning, symbol: "exclamationmark.triangle.fill") }
                if live > 0 { Chip(text: "\(live) live", tint: Palette.positive, symbol: "bolt.fill") }
                if store.state.accounts.isEmpty { Chip(text: "None yet", tint: .secondary) }
            }
        }
        .surface(padding: 18, radius: 22)
        .frame(height: 140)
    }

    private var renewalTile: some View {
        let next = store.state.subscriptions.min { $0.nextRenewal < $1.nextRenewal }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Next renewal").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if let next { LogoCircle(integrationID: account(next.accountID)?.integrationID, size: 28, symbol: "calendar") }
            }
            if let next {
                let days = daysUntil(next.nextRenewal)
                MoneyText(money: next.price, size: 28, weight: .heavy)
                HStack(spacing: 6) {
                    Text(next.name).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                    Chip(text: relativeDays(days), tint: days < 0 ? Palette.negative : days <= 7 ? Palette.warning : .secondary)
                }
            } else {
                Text("Nothing scheduled").font(.system(size: 20, weight: .bold)).foregroundStyle(.secondary)
                Button("Add Subscription") { editor = .subscription(nil) }.buttonStyle(PillButtonStyle(compact: true))
            }
        }
        .surface(padding: 18, radius: 22)
        .frame(height: 140)
    }

    private var addWalletCard: some View {
        Button { destination = .catalogue } label: {
            VStack(spacing: 10) {
                Image(systemName: "plus").font(.system(size: 18, weight: .bold))
                    .frame(width: 44, height: 44).background(Circle().fill(Palette.raised))
                Text("Add wallet").font(.system(size: 13, weight: .semibold))
                Text("OpenRouter, DeepSeek or manual").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .frame(width: 200, height: 178)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Palette.border, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func signIn(_ account: ConnectedAccount) {
        signingIn.insert(account.id)
        Task {
            do {
                try await SignIn.start(account.integrationID)
                if account.integrationID == "codex" {
                    signingIn.remove(account.id)
                    await store.refreshAccount(account.id)
                } else {
                    store.notice = "Finish signing in to Claude in the Terminal window, then click Refresh on this wallet."
                }
            } catch { store.notice = error.localizedDescription }
            signingIn.remove(account.id)
        }
    }

    @ViewBuilder private func walletMenuItems(_ account: ConnectedAccount) -> some View {
        if account.mode == .live { Button("Refresh Balance") { Task { await store.refreshAccount(account.id) } } }
        if SignIn.supports(account.integrationID) { Button(SignIn.title(account.integrationID)) { signIn(account) } }
        Button("Edit Account") { if let integration = Catalogue.integration(account.integrationID) { editor = .account(integration, account) } }
        Button("Add Payment") { editor = .payment(.init(accountID: account.id, description: "", kind: .topUp, money: Money(0, "USD"), paidAt: .now)) }
        Divider()
        Button("Remove Account", role: .destructive) { removal = .init(title: "Remove \(account.label)?", action: { try store.removeAccount(account.id) }) }
    }

    private var transactionsPanel: some View {
        let items = Array(store.state.payments.filter { matches($0.description, accountName($0.accountID)) }.sorted { $0.paidAt > $1.paidAt }.prefix(5))
        return VStack(alignment: .leading, spacing: 8) {
            SectionHeading(title: "Transactions", subtitle: "Recorded") { SeeAllButton { destination = .payments } }
                .padding(.bottom, 6)
            if items.isEmpty {
                emptyState("No payments yet", "Record a top-up or subscription charge from a receipt.", "creditcard")
            }
            ForEach(items) { transactionRow($0) }
        }
        .surface(padding: 20, radius: 22)
    }

    private func transactionRow(_ record: PaymentRecord, actions: Bool = false) -> some View {
        let refund = record.kind == .refund
        return HStack(spacing: 14) {
            LogoCircle(integrationID: account(record.accountID)?.integrationID, size: 42, symbol: refund ? "arrow.uturn.backward" : "creditcard")
            VStack(alignment: .leading, spacing: 3) {
                Text(record.description).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(record.paidAt.formatted(date: .abbreviated, time: .omitted) + " · " + accountName(record.accountID))
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 4) {
                MoneyText(money: record.money, size: 15, prefix: refund ? "+" : "−")
                    .foregroundStyle(refund ? Palette.positive : Color.primary)
                Text(refund ? "Refunded" : record.kind.rawValue).font(.system(size: 11, weight: .medium)).foregroundStyle(refund ? Palette.positive : .secondary)
            }
            if actions {
                Button { editor = .payment(record) } label: { Image(systemName: "pencil") }
                    .buttonStyle(IconButtonStyle()).help("Edit").accessibilityLabel("Edit \(record.description)")
                Button { removal = .init(title: "Remove Payment?", action: { try store.removePayment(record.id) }) } label: { Image(systemName: "trash") }
                    .buttonStyle(IconButtonStyle()).help("Remove").accessibilityLabel("Remove \(record.description)")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RowHighlight())
        .contextMenu {
            Button("Edit") { editor = .payment(record) }
            Button("Remove", role: .destructive) { removal = .init(title: "Remove Payment?", action: { try store.removePayment(record.id) }) }
        }
    }

    private var spendingPanel: some View {
        let currency = activeCurrency
        let slices = SpendSeries.byProvider(store.state.payments, accounts: store.state.accounts, currency: currency)
        return VStack(alignment: .leading, spacing: 16) {
            SectionHeading(title: "Spending") {
                if chartCurrencies.count > 1 { PillMenu(options: chartCurrencies, selection: currencyBinding) { $0 } }
            }
            if slices.isEmpty {
                Text("No payments in \(currency) yet.").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                ProviderDonut(slices: Array(slices.prefix(5)), currency: currency).frame(maxWidth: .infinity)
            }
        }
        .surface(padding: 20, radius: 22)
    }

    private var releasesStrip: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeading(title: "Latest Releases") { SeeAllButton { destination = .releases } }
            HStack(spacing: 14) {
                ForEach(recentReleases(limit: 3)) { entry in
                    Link(destination: entry.item.url) {
                        HStack(spacing: 12) {
                            LogoCircle(integrationID: "github-releases", size: 38)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(entry.item.tag).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(Palette.hex(0x15161B))
                                        .padding(.horizontal, 6).frame(height: 18).background(Capsule().fill(Palette.lime))
                                    if entry.item.prerelease { Chip(text: "Pre", tint: Palette.warning) }
                                }
                                Text(entry.item.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                                Text(entry.repo.slug).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .surface(padding: 14, radius: 18)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Wallets

    private var wallets: some View {
        let items = store.state.accounts.filter { matches($0.label, $0.billingScope, integrationName($0)) }
        let attention = store.state.accounts.filter(needsAttention).count
        return VStack(alignment: .leading, spacing: 0) {
            pageHeader("Wallets", "Each account keeps its own label, billing owner, key and currency.",
                       chip: store.state.accounts.isEmpty ? nil : attention > 0 ? Chip(text: "\(attention) need attention", tint: Palette.warning, symbol: "exclamationmark.triangle.fill") : Chip(text: "All current", tint: Palette.positive, symbol: "checkmark"))
            if items.isEmpty {
                Group {
                    if store.state.accounts.isEmpty {
                        emptyState("No wallets yet", "Connect OpenRouter or DeepSeek for live balances, or add any provider as a manual account.", "wallet.pass",
                                   action: "Browse Catalogue") { destination = .catalogue }
                    } else {
                        emptyState("No matching wallets", "Try a different search.", "magnifyingglass")
                    }
                }
                .surface()
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: 18, alignment: .top)], spacing: 18) {
                ForEach(items) { walletTile($0) }
            }
        }
    }

    private func walletTile(_ account: ConnectedAccount) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            WalletCard(account: account, paid: paidTotals(for: account), height: 190)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    if account.mode == .live {
                        Button { Task { await store.refreshAccount(account.id) } } label: {
                            HStack(spacing: 6) {
                                if store.refreshingAccounts.contains(account.id) { ProgressView().controlSize(.mini) }
                                else { Image(systemName: "arrow.clockwise") }
                                Text("Refresh")
                            }
                        }
                        .buttonStyle(PillButtonStyle(compact: true))
                        .disabled(store.refreshingAccounts.contains(account.id) || store.loadFailure != nil)
                        .accessibilityLabel("Refresh \(account.label) \(integrationName(account))")
                    }
                    if SignIn.supports(account.integrationID) {
                        Button { signIn(account) } label: {
                            HStack(spacing: 6) {
                                if signingIn.contains(account.id) { ProgressView().controlSize(.mini) } else { Image(systemName: "person.crop.circle.badge.checkmark") }
                                Text("Sign In")
                            }
                        }
                        .buttonStyle(PillButtonStyle(compact: true))
                        .disabled(signingIn.contains(account.id))
                        .help(SignIn.title(account.integrationID))
                    }
                    Button { if let integration = Catalogue.integration(account.integrationID) { editor = .account(integration, account) } } label: { Label("Edit", systemImage: "pencil") }
                        .buttonStyle(PillButtonStyle(compact: true))
                    Spacer()
                    moreMenu("Options for \(account.label)") { walletMenuItems(account) }
                }
                if let windows = account.snapshot?.allowances, !windows.isEmpty {
                    VStack(spacing: 10) {
                        ForEach(windows) { window in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(window.name).font(.system(size: 12, weight: .semibold))
                                    Spacer()
                                    Text("\(window.usedPercent)% used").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                                        .foregroundStyle(window.usedPercent >= 100 ? Palette.negative : window.usedPercent >= 80 ? Palette.warning : Color.primary)
                                }
                                UsageMeter(used: Double(window.usedPercent) / 100,
                                           tint: window.usedPercent >= 100 ? Palette.negative : window.usedPercent >= 80 ? Palette.warning : Palette.series(account.integrationID),
                                           track: Palette.raised)
                                if let reset = window.resetsAt {
                                    Text("Resets \(reset.formatted(.relative(presentation: .named))) · \(reset.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                if let snapshot = account.snapshot {
                    let period = snapshot.consumptionPeriod.map { " (\($0.lowercased()))" } ?? ""
                    let detailRows = snapshot.details.map { ($0.label, $0.value) } + snapshot.reportedConsumption.map { ("Reported consumption\(period)", $0) }
                    if let plan = snapshot.plan {
                        HStack { Text("Plan").foregroundStyle(.secondary); Spacer(); Text(plan).font(.system(size: 12, weight: .semibold)) }.font(.system(size: 12))
                    }
                    VStack(spacing: 8) {
                        ForEach(Array(detailRows.enumerated()), id: \.offset) { _, row in
                            HStack {
                                Text(row.0).foregroundStyle(.secondary)
                                Spacer()
                                Text(row.1.plainText).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                            }
                            .font(.system(size: 12))
                            .accessibilityElement(children: .ignore).accessibilityLabel("\(row.0), \(row.1.formatted)")
                        }
                    }
                    Text(snapshot.coverage).font(.system(size: 11)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Text("Updated \(snapshot.observedAt.formatted(date: .abbreviated, time: .shortened))")
                        Spacer()
                        Link(destination: snapshot.source) { Label("Source", systemImage: "arrow.up.right") }
                    }
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                } else {
                    Text(account.mode == .manual ? "Manual records only. Balance and allowance are unavailable." : "No balance reading yet. Refresh to check this account.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if let error = account.lastError {
                    InlineNotice(text: error + (account.lastAttempt.map { " Last attempt \($0.formatted(date: .abbreviated, time: .shortened))." } ?? ""))
                }
            }
            .padding(.horizontal, 6)
        }
        .padding(10).padding(.bottom, 6)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(Palette.border))
    }

    // MARK: Payments

    private var payments: some View {
        let currency = activeCurrency
        let month = SpendSeries.paidThisMonth(store.state.payments, currency: currency)
        let items = store.state.payments.filter { matches($0.description, $0.reference, accountName($0.accountID), $0.money.currency) }.sorted { $0.paidAt > $1.paidAt }
        return VStack(alignment: .leading, spacing: 18) {
            pageHeader("Payments", "Settled charges and refunds from receipts. Amounts stay grouped by currency.",
                       chip: month > 0 ? Chip(text: "+\(Money(Decimal(month), currency).amountText) \(currency) this month", tint: Palette.lime, symbol: "arrow.up.right", filled: true) : nil)
                .padding(.bottom, -18)
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Spend over time").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                            if let total = Ledger.paidTotals(store.state.payments).first(where: { $0.currency == currency }) { MoneyText(money: total, size: 30, weight: .heavy) }
                        }
                        Spacer()
                        SegmentedPills(options: ["Cumulative", "Monthly"], selection: $chartMode) { $0 }
                        if chartCurrencies.count > 1 { PillMenu(options: chartCurrencies, selection: currencyBinding) { $0 } }
                    }
                    if store.state.payments.contains(where: { $0.money.currency == currency }) {
                        if chartMode == "Monthly" {
                            MonthlyBarsChart(months: SpendSeries.monthly(store.state.payments, accounts: store.state.accounts, currency: currency), currency: currency)
                        } else {
                            SpendAreaChart(points: SpendSeries.cumulative(store.state.payments, currency: currency, start: store.state.coverageStart), currency: currency)
                        }
                    } else {
                        emptyState("No chart yet", "Payments appear here once recorded.", "chart.xyaxis.line")
                    }
                }
                .surface(padding: 22, radius: 22)
                .frame(height: 300)
                VStack(alignment: .leading, spacing: 14) {
                    Text("Totals").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                    let totals = Ledger.paidTotals(store.state.payments)
                    if totals.isEmpty { Text("Nothing recorded").font(.system(size: 20, weight: .bold)).foregroundStyle(.secondary) }
                    ForEach(totals) { MoneyText(money: $0, size: 26, weight: .heavy) }
                    Spacer(minLength: 0)
                    Chip(text: store.state.historyCoverage?.completeForPeriod == true ? "Complete for period" : "Partial history",
                         tint: store.state.historyCoverage?.completeForPeriod == true ? Palette.positive : Palette.warning)
                    Text(store.state.coverageDescription).font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("Set Coverage") { editor = .coverage }.buttonStyle(PillButtonStyle(compact: true))
                }
                .surface(padding: 22, radius: 22)
                .frame(width: 260, height: 300)
            }
            VStack(alignment: .leading, spacing: 4) {
                SectionHeading(title: "History", subtitle: "\(items.count) record\(items.count == 1 ? "" : "s")").padding(.bottom, 10)
                if items.isEmpty { emptyState("No matching payments", "Add a confirmed payment to begin your recorded history.", "creditcard") }
                let groups = Dictionary(grouping: items) { Calendar.current.dateInterval(of: .month, for: $0.paidAt)?.start ?? $0.paidAt }
                ForEach(groups.keys.sorted(by: >), id: \.self) { month in
                    Text(month.formatted(.dateTime.month(.wide).year()).uppercased())
                        .font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(.tertiary)
                        .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 2)
                    ForEach(groups[month] ?? []) { record in
                        transactionRow(record, actions: true)
                    }
                }
            }
            .surface(padding: 20, radius: 22)
        }
    }

    // MARK: Subscriptions

    private var subscriptions: some View {
        let items = store.state.subscriptions.filter { matches($0.name, accountName($0.accountID)) }.sorted { $0.nextRenewal < $1.nextRenewal }
        let monthly = Dictionary(grouping: store.state.subscriptions, by: { $0.price.currency }).map { currency, list in
            Money(list.reduce(Decimal(0)) { $0 + ($1.cadence == .yearly ? $1.price.amount / 12 : $1.price.amount) }, currency)
        }.sorted { $0.currency < $1.currency }
        return VStack(alignment: .leading, spacing: 0) {
            pageHeader("Subscriptions", "Expected charges stay separate from payment history. Record each settled renewal when it happens.",
                       chip: monthly.first.map { Chip(text: "\($0.plainText) / month expected", tint: Palette.accent, symbol: "repeat") })
            if items.isEmpty {
                emptyState(store.state.subscriptions.isEmpty ? "No subscriptions yet" : "No matching subscriptions", "Add a schedule for a plan you already pay for.", "calendar",
                           action: store.state.subscriptions.isEmpty ? "Add Subscription" : nil) { editor = .subscription(nil) }.surface()
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 18, alignment: .top)], spacing: 18) {
                ForEach(items) { planCard($0) }
            }
        }
    }

    private func planCard(_ schedule: SubscriptionSchedule) -> some View {
        let linked = account(schedule.accountID)
        let days = daysUntil(schedule.nextRenewal)
        return ZStack(alignment: .topLeading) {
            MeshBackdrop(colors: Palette.brand(linked?.integrationID))
            if let id = linked?.integrationID {
                ProviderLogo(integrationID: id, size: 140, ink: .white).opacity(0.12).rotationEffect(.degrees(-14))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).offset(x: 30, y: -24)
                    .allowsHitTesting(false)
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 8) {
                    LogoCircle(integrationID: linked?.integrationID, size: 38, symbol: "calendar", onColor: true)
                    Spacer()
                    GlassChip(text: relativeDays(days), dot: days < 0 ? Palette.negative : days <= 7 ? Palette.warning : Palette.lime)
                    moreMenu("Options for \(schedule.name)", onColor: true) {
                        Button("Edit Schedule") { editor = .subscription(schedule) }
                        Button("Record Settled Payment") { editor = .payment(.init(accountID: schedule.accountID, description: schedule.name, kind: .subscription, money: schedule.price, paidAt: .now)) }
                        Divider()
                        Button("Remove Schedule", role: .destructive) { removal = .init(title: "Remove Schedule?", action: { try store.removeSubscription(schedule.id) }) }
                    }
                }
                Spacer(minLength: 14)
                Text(schedule.name).font(.system(size: 22, weight: .heavy)).tracking(-0.5).lineLimit(1)
                Text(accountName(schedule.accountID)).font(.system(size: 12, weight: .medium)).opacity(0.75).lineLimit(1)
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Next charge").font(.system(size: 11, weight: .medium)).opacity(0.7)
                        Text(schedule.nextRenewal.formatted(.dateTime.month(.abbreviated).day().year())).font(.system(size: 15, weight: .bold))
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(schedule.cadence.rawValue).font(.system(size: 11, weight: .medium)).opacity(0.7)
                        MoneyText(money: schedule.price, size: 22)
                    }
                }
                .padding(.top, 14)
                if days < 0 {
                    Text("Date passed. Confirm the payment and update the schedule.").font(.system(size: 11, weight: .semibold))
                        .padding(.top, 10)
                }
            }
            .padding(20)
        }
        .foregroundStyle(.white)
        .frame(height: days < 0 ? 236 : 214)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Color.white.opacity(0.14)))
        .shadow(color: Palette.brand(linked?.integrationID)[1].opacity(0.28), radius: 16, y: 8)
        .contextMenu {
            Button("Edit Schedule") { editor = .subscription(schedule) }
            Button("Record Settled Payment") { editor = .payment(.init(accountID: schedule.accountID, description: schedule.name, kind: .subscription, money: schedule.price, paidAt: .now)) }
        }
    }

    // MARK: Catalogue

    private var catalogue: some View {
        let items = Catalogue.integrations.filter { (category == nil || $0.category == category) && matches($0.name, $0.capabilities, $0.method, $0.status.rawValue) }
        return VStack(alignment: .leading, spacing: 0) {
            pageHeader("Catalogue", "Connect a supported service, add manual records, or see what is planned.")
            SegmentedPills(options: [nil] + IntegrationCategory.allCases.map(Optional.some), selection: $category) { $0?.rawValue ?? "All" }
                .padding(.bottom, 24)
            if items.isEmpty { emptyState("No matching services", "Try another search or choose All.", "magnifyingglass").surface() }
            VStack(alignment: .leading, spacing: 30) {
                ForEach([IntegrationStatus.ready, .manual, .planned], id: \.self) { status in
                    let group = items.filter { $0.status == status }
                    if !group.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            SectionHeading(title: status.rawValue, subtitle: "\(group.count)")
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 16, alignment: .top)], spacing: 16) {
                                ForEach(group) { catalogueTile($0) }
                            }
                        }
                    }
                }
            }
        }
    }

    private func statusTint(_ status: IntegrationStatus) -> Color {
        switch status {
        case .ready: return Palette.positive
        case .manual: return Palette.accent
        case .planned: return .secondary
        }
    }

    private func catalogueTile(_ integration: Integration) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                LogoCircle(integrationID: integration.id, size: 46, onColor: integration.status == .ready)
                    .background(Circle().fill(Palette.series(integration.id).opacity(integration.status == .ready ? 0.5 : 0)).blur(radius: 14))
                Spacer()
                Chip(text: integration.status == .ready ? "Live" : integration.status == .manual ? "Manual" : "Planned",
                     tint: statusTint(integration.status),
                     symbol: integration.status == .ready ? "bolt.fill" : integration.status == .manual ? "square.and.pencil" : "clock")
            }
            .padding(.bottom, 4)
            Text(integration.name).font(.system(size: 15, weight: .bold)).lineLimit(1)
            Text(integration.capabilities).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Text(integration.limitation).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(2).help(integration.limitation)
            Spacer(minLength: 4)
            HStack {
                if let source = integration.source {
                    Link(destination: source) { Label("Docs", systemImage: "arrow.up.right") }
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        .help(integration.evidence.rawValue).accessibilityLabel("Source for \(integration.name)")
                }
                Spacer()
                if integration.id == "github-releases" {
                    Button("Follow Repository") { editor = .repository }.buttonStyle(PillButtonStyle(kind: .primary, compact: true))
                } else if integration.category == .providers || integration.category == .subscriptions {
                    if integration.status == .ready {
                        Button("Add Account") { editor = .account(integration, nil) }.buttonStyle(PillButtonStyle(kind: .primary, compact: true))
                    } else {
                        Button("Add Manual Account") { editor = .account(integration, nil) }.buttonStyle(PillButtonStyle(compact: true))
                    }
                }
            }
        }
        .frame(minHeight: 190, alignment: .topLeading)
        .surface(padding: 18, radius: 22)
        .opacity(integration.status == .planned ? 0.72 : 1)
    }

    // MARK: Releases

    private struct ReleaseEntry: Identifiable { let repo: WatchedRepository; let item: ReleaseItem; var id: String { "\(repo.id)-\(item.id)" } }

    private func recentReleases(limit: Int) -> [ReleaseEntry] {
        store.state.repositories.flatMap { repo in store.state.visibleReleases(for: repo).map { ReleaseEntry(repo: repo, item: $0) } }
            .sorted { ($0.item.publishedAt ?? .distantPast) > ($1.item.publishedAt ?? .distantPast) }
            .prefix(limit).map { $0 }
    }

    private var releases: some View {
        VStack(alignment: .leading, spacing: 18) {
            pageHeader("Releases", "Latest 50 public releases per repository. Manual refresh, up to every 30 minutes, no sign-in. Up to 10 repositories share a 20-request hourly budget.")
                .padding(.bottom, -18)
            if store.state.repositories.isEmpty {
                emptyState("Follow a project", "Add a public repository to see its source-linked releases.", "shippingbox", action: "Follow Repository") { editor = .repository }.surface()
            }
            ForEach(store.state.repositories.filter { matches($0.slug) || $0.releases.contains { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.tag.localizedCaseInsensitiveContains(search) } }) { repository in
                repositoryPanel(repository)
            }
        }
    }

    private func repositoryPanel(_ repository: WatchedRepository) -> some View {
        let items = store.state.visibleReleases(for: repository).filter { search.isEmpty || repository.slug.localizedCaseInsensitiveContains(search) || $0.title.localizedCaseInsensitiveContains(search) || $0.tag.localizedCaseInsensitiveContains(search) }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                LogoCircle(integrationID: "github-releases", size: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text(repository.slug).font(.system(size: 15, weight: .bold))
                    Text(repository.lastSuccess.map { "Checked \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Not checked yet")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                if let date = repository.nextAllowedRefresh, date > .now {
                    Chip(text: "Next after \(date.formatted(date: .omitted, time: .shortened))", tint: .secondary, symbol: "hourglass")
                }
                Toggle("Prereleases", isOn: Binding(get: { repository.includePrereleases }, set: { value in perform { try store.setPrereleases(repository.id, include: value) } }))
                    .toggleStyle(.switch).controlSize(.mini).font(.system(size: 12, weight: .medium))
                    .accessibilityLabel("Include Prereleases")
                Link(destination: URL(string: "https://github.com/\(repository.slug)")!) { Image(systemName: "arrow.up.right") }
                    .buttonStyle(IconButtonStyle()).help("Open on GitHub")
                Button { Task { await store.refreshRepository(repository.id) } } label: {
                    if store.refreshingRepositories.contains(repository.id) { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .buttonStyle(IconButtonStyle()).help("Refresh releases")
                .disabled(store.refreshingRepositories.contains(repository.id) || store.loadFailure != nil).accessibilityLabel("Refresh \(repository.slug)")
                Button { removal = .init(title: "Unfollow \(repository.slug)?", action: { try store.removeRepository(repository.id) }) } label: { Image(systemName: "trash") }
                    .buttonStyle(IconButtonStyle()).help("Unfollow").accessibilityLabel("Unfollow \(repository.slug)")
            }
            .padding(.bottom, 4)
            if items.isEmpty {
                Text(repository.lastSuccess == nil ? "No release reading yet. Refresh to check this repository." : "No matching published releases in the latest 50.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 6)
            }
            ForEach(items) { item in
                Link(destination: item.url) {
                    HStack(spacing: 12) {
                        Text(item.tag).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(Palette.hex(0x15161B))
                            .padding(.horizontal, 8).frame(height: 22).background(Capsule().fill(item.prerelease ? Palette.warning : Palette.lime))
                            .fixedSize()
                        Text(item.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                        if item.prerelease { Chip(text: "Prerelease", tint: Palette.warning) }
                        Spacer(minLength: 12)
                        if let date = item.publishedAt { Text(date.formatted(date: .abbreviated, time: .omitted)).font(.system(size: 12)).foregroundStyle(.secondary) }
                        Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 9)
                    .background(RowHighlight())
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(item.title), \(item.tag)\(item.prerelease ? ", prerelease" : "")")
            }
            if let error = repository.lastError { InlineNotice(text: error) }
        }
        .surface(padding: 20, radius: 22)
    }
}

/// Hover highlight for rows inside surfaces.
struct RowHighlight: View {
    @State private var hovering = false
    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Palette.raised.opacity(hovering ? 0.7 : 0))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
