import SwiftUI
import AppKit
import UnifaiCore

@main
struct UnifaiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store: AppStore
    private let fixtureMode: Bool

    init() {
        let args = CommandLine.arguments
        fixtureMode = args.contains("--fixture-mode") || Bundle.main.object(forInfoDictionaryKey: "UnifaiFixtureMode") as? Bool == true
        let directory: URL
        if let index = args.firstIndex(of: "--data-directory"), args.indices.contains(index + 1), args[index + 1].hasPrefix("/") {
            directory = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        } else if fixtureMode, let path = Bundle.main.object(forInfoDictionaryKey: "UnifaiDataDirectory") as? String {
            directory = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(fixtureMode ? "Unifai Fixtures" : "Unifai", isDirectory: true)
        }
        let repository = StateRepository(directory: directory)
        let model: AppStore
        if fixtureMode {
            let vault = MemoryVault()
            model = AppStore(repository: repository, vault: vault,
                             balances: FixtureWorkspace.balance, releases: FixtureWorkspace.releases)
            if !args.contains("--fixture-empty"), Bundle.main.object(forInfoDictionaryKey: "UnifaiFixtureEmpty") as? Bool != true, model.loadFailure == nil {
                do { try FixtureWorkspace.prepare(model, vault: vault) }
                catch { model.notice = "Fixture setup failed: \(error.localizedDescription)" }
            }
            if Bundle.main.object(forInfoDictionaryKey: "UnifaiKeychainCheck") as? Bool == true {
                FixtureWorkspace.checkNativeKeychain(directory: directory)
            }
        } else { model = AppStore(repository: repository) }
        AppRuntime.store = model
        AppRuntime.fixtureMode = fixtureMode
        // Fixture-only: open a specific screen for visual verification.
        if fixtureMode, let index = args.firstIndex(of: "--destination"), args.indices.contains(index + 1) {
            AppRuntime.initialDestination = Destination(rawValue: args[index + 1])
        }
        _store = StateObject(wrappedValue: model)
    }
    var body: some Scene {
        Window("Unifai", id: "main") {
            MainView(fixtureMode: fixtureMode).environmentObject(store)
                .frame(minWidth: 1180, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1400, height: 900)
        .commands { MainWindowCommands() }
    }
}

struct MainWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Show Unifai") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }.keyboardShortcut("1", modifiers: .command)
            Button("Show Companion") { AppRuntime.showCompanion?() }.keyboardShortcut("m", modifiers: [.command, .shift])
        }
    }
}

@MainActor enum AppRuntime {
    static var store: AppStore?
    static var fixtureMode = false
    static var initialDestination: Destination?
    static var showCompanion: (() -> Void)?
    static var openMain: (() -> Void)?
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var companion: MenuBarController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let icon = AppIconArtwork.render() { NSApp.applicationIconImage = icon }
        if let store = AppRuntime.store {
            companion = MenuBarController(store: store, fixtureMode: AppRuntime.fixtureMode)
            AppRuntime.showCompanion = { [weak self] in self?.companion?.toggle() }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AppRuntime.openMain?() }
        return true
    }
}

struct MenuPanel: View {
    @EnvironmentObject private var store: AppStore
    let fixtureMode: Bool
    var body: some View {
        let totals = Ledger.paidTotals(store.state.payments)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                AppMark(size: 24)
                Text("Unifai").font(.system(size: 14, weight: .bold))
                Spacer()
                if fixtureMode { Chip(text: "Demo", tint: Palette.warning, symbol: "testtube.2") }
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let error = store.loadFailure { InlineNotice(text: error) }
                    ZStack(alignment: .topLeading) {
                        MeshBackdrop(colors: Palette.hero)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Total paid for AI").font(.system(size: 12, weight: .semibold)).opacity(0.85)
                            if totals.isEmpty { Text("Nothing yet").font(.system(size: 24, weight: .heavy)) }
                            ForEach(totals) { MoneyText(money: $0, size: totals.count > 1 ? 22 : 28, weight: .heavy) }
                            Text(store.state.coverageDescription).font(.system(size: 10, weight: .medium)).opacity(0.75)
                        }
                        .padding(16)
                    }
                    .foregroundStyle(.white)
                    .frame(height: totals.count > 1 ? 136 : 112)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    Text("Wallets").font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary)
                    if store.state.accounts.isEmpty { Text("No accounts connected").font(.system(size: 12)).foregroundStyle(.secondary) }
                    ForEach(store.state.accounts) { account in
                        HStack(spacing: 10) {
                            LogoCircle(integrationID: account.integrationID, size: 32)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(Catalogue.integration(account.integrationID)?.name ?? account.integrationID).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                Text(account.label).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 3) {
                                if let snapshot = account.snapshot {
                                    ForEach(snapshot.balances) { MoneyText(money: $0, size: 13) }
                                    if account.lastError != nil || snapshot.isStale() { Chip(text: "Needs attention", tint: Palette.warning) }
                                } else { Text(account.mode == .manual ? "Manual" : "Not refreshed").font(.system(size: 11)).foregroundStyle(.tertiary) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Rectangle().fill(Palette.border).frame(height: 1)
            HStack {
                Button("Open Unifai") { AppRuntime.openMain?() }.buttonStyle(PillButtonStyle(kind: .primary, compact: true))
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(PillButtonStyle(compact: true)).accessibilityLabel("Quit Unifai").keyboardShortcut("q")
            }.padding(12)
        }
        .frame(width: 340, height: 500)
        .background(Palette.canvas)
    }
}

@MainActor final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    init(store: AppStore, fixtureMode: Bool) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 340, height: 500)
        popover.contentViewController = NSHostingController(rootView: MenuPanel(fixtureMode: fixtureMode).environmentObject(store))
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: "Unifai")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "Unifai"
            button.setAccessibilityLabel("Unifai")
            button.target = self; button.action = #selector(toggle)
        }
    }
    @objc func toggle() {
        if popover.isShown { popover.performClose(nil) }
        else if let button = statusItem.button {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
