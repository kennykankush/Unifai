import Foundation

/// What the desktop widgets show, computed by the app and written to the shared app group container.
/// The widget only draws it: no credentials, no network and no ledger logic in the extension.
public struct WidgetSnapshot: Codable, Equatable {
    public struct Spend: Codable, Equatable {
        /// This month's payments plus pay-as-you-go usage, in one currency.
        public var thisMonth: Money
        public var accruing: Money?
        public var budget: Money?
        /// The last six months, oldest first, in the same currency.
        public var months: [Double]
        public var monthLabels: [String]
        public var complete: Bool
        public init(thisMonth: Money, accruing: Money?, budget: Money?, months: [Double], monthLabels: [String], complete: Bool) {
            self.thisMonth = thisMonth; self.accruing = accruing; self.budget = budget
            self.months = months; self.monthLabels = monthLabels; self.complete = complete
        }
        public var budgetUsed: Double? {
            guard let budget, budget.amount > 0 else { return nil }
            return NSDecimalNumber(decimal: thisMonth.amount / budget.amount).doubleValue
        }
    }

    public struct Window: Codable, Equatable {
        public var name: String
        public var usedPercent: Int
        public var resetsAt: Date?
        public init(name: String, usedPercent: Int, resetsAt: Date?) { self.name = name; self.usedPercent = usedPercent; self.resetsAt = resetsAt }
    }

    public struct Wallet: Codable, Equatable, Identifiable {
        public var id: String
        public var name: String
        public var label: String
        /// Logo resource name in the widget bundle, such as "codex-color".
        public var logo: String?
        /// Brand gradient stops as 0xRRGGBB.
        public var colors: [UInt32]
        public var caption: String
        public var value: Money?
        public var text: String?
        public var windows: [Window]
        public var status: String?
        public var alert: Bool
        public init(id: String, name: String, label: String, logo: String?, colors: [UInt32], caption: String, value: Money?, text: String?,
                    windows: [Window], status: String?, alert: Bool) {
            self.id = id; self.name = name; self.label = label; self.logo = logo; self.colors = colors; self.caption = caption
            self.value = value; self.text = text; self.windows = windows; self.status = status; self.alert = alert
        }
    }

    public struct Room: Codable, Equatable {
        public var name: String
        public var label: String
        public var logo: String?
        public var usable: Bool
        public var headline: String
        public var remaining: Double?
        public var nextReset: Date?
        public var freeResets: Int
        public init(name: String, label: String, logo: String?, usable: Bool, headline: String, remaining: Double?, nextReset: Date?, freeResets: Int) {
            self.name = name; self.label = label; self.logo = logo; self.usable = usable; self.headline = headline
            self.remaining = remaining; self.nextReset = nextReset; self.freeResets = freeResets
        }
    }

    public struct Renewal: Codable, Equatable {
        public var name: String
        public var price: Money
        public var date: Date
        public var logo: String?
        public init(name: String, price: Money, date: Date, logo: String?) { self.name = name; self.price = price; self.date = date; self.logo = logo }
    }

    public struct Event: Codable, Equatable {
        public var title: String
        public var kind: String
        public var date: Date
        public var important: Bool
        public init(title: String, kind: String, date: Date, important: Bool) { self.title = title; self.kind = kind; self.date = date; self.important = important }
    }

    public var generatedAt: Date
    public var spend: Spend?
    public var nextRenewal: Renewal?
    public var wallets: [Wallet]
    public var room: [Room]
    public var events: [Event]
    public init(generatedAt: Date, spend: Spend?, nextRenewal: Renewal?, wallets: [Wallet], room: [Room], events: [Event]) {
        self.generatedAt = generatedAt; self.spend = spend; self.nextRenewal = nextRenewal
        self.wallets = wallets; self.room = room; self.events = events
    }
}

/// The shared container between the app and its widget extension. The app group is
/// "<Team ID>.dev.unifai", set at build time in both Info.plists as UnifaiAppGroup.
public enum WidgetStore {
    public static func fileURL(bundle: Bundle = .main) -> URL? {
        guard let group = bundle.object(forInfoDictionaryKey: "UnifaiAppGroup") as? String, !group.isEmpty,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        let channel = bundle.object(forInfoDictionaryKey: "UnifaiChannel") as? String ?? "release"
        return container.appendingPathComponent("widget-\(channel).json")
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    public static func load(bundle: Bundle = .main) -> WidgetSnapshot? {
        guard let url = fileURL(bundle: bundle), let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder().decode(WidgetSnapshot.self, from: data)
    }

    /// Writes only when the content changed, so unchanged refreshes do not spend the widget reload budget.
    @discardableResult
    public static func save(_ snapshot: WidgetSnapshot, bundle: Bundle = .main) -> Bool {
        guard let url = fileURL(bundle: bundle) else { return false }
        if var previous = load(bundle: bundle), snapshot.generatedAt.timeIntervalSince(previous.generatedAt) < 3600 {
            previous.generatedAt = snapshot.generatedAt
            if previous == snapshot { return false }
        }
        guard let data = try? encoder().encode(snapshot) else { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}
