import SwiftUI
import AppKit
import WidgetKit
import UnifaiCore

// Desktop widget views, shared by the widget extension and the app's preview export.
// Same language as the app: brand gradients, logo circles, big tight numerals, lime accents.

public enum WidgetSize { case small, medium, large }

enum WidgetPalette {
    static func hex(_ value: UInt32, _ alpha: Double = 1) -> Color {
        Color(.sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255, opacity: alpha)
    }
    static let ink = hex(0x15161B)
    static let lime = hex(0xC8F542)
    static let negative = hex(0xFF5C5C)
    static let warning = hex(0xFFA53D)
    static let hero: [UInt32] = [0x3D1FD8, 0x8A3BFF, 0xFF6A88]
    static let room: [UInt32] = [0x0E3B33, 0x12715B, 0x6E8F1E]
    static let dark: [UInt32] = [0x0B0B0D, 0x17171B, 0x24242B]
}

/// Mesh-like gradient from three stops, without blur, which widgets render cheaply.
public struct WidgetGradient: View {
    let colors: [UInt32]
    public init(_ colors: [UInt32]) { self.colors = colors.count >= 3 ? colors : [0x2C2D36, 0x41434F, 0x6A6D7C] }
    public var body: some View {
        ZStack {
            LinearGradient(colors: [WidgetPalette.hex(colors[0]), WidgetPalette.hex(colors[1])], startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [WidgetPalette.hex(colors[2], 0.9), .clear], center: UnitPoint(x: 1, y: 1), startRadius: 0, endRadius: 220)
            RadialGradient(colors: [Color.white.opacity(0.16), .clear], center: UnitPoint(x: 0.85, y: 0.1), startRadius: 0, endRadius: 140)
        }
    }
}

struct Logo: View {
    let name: String?
    var size: CGFloat = 22
    var body: some View {
        ZStack {
            Circle().fill(Color.white)
            if let image = Self.image(name) {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .frame(width: size * 0.62, height: size * 0.62)
                    .foregroundStyle(WidgetPalette.ink)
            } else {
                Image(systemName: "creditcard.fill").font(.system(size: size * 0.4, weight: .bold)).foregroundStyle(WidgetPalette.ink)
            }
        }
        .frame(width: size, height: size)
    }
    static func image(_ name: String?) -> NSImage? {
        guard let name, let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Logos"),
              let image = NSImage(contentsOf: url) else { return nil }
        // Monochrome logos are templates in the app; on the white circle they print in ink.
        image.isTemplate = !name.hasSuffix("-color")
        return image
    }
}

struct AppGlyph: View {
    var size: CGFloat = 18
    var body: some View {
        Image(systemName: "square.stack.3d.up.fill")
            .font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(LinearGradient(colors: [WidgetPalette.hex(0x7C5CFF), WidgetPalette.hex(0x4B2FE0)], startPoint: .top, endPoint: .bottom)))
    }
}

struct Meter: View {
    let value: Double
    var tint: Color = .white
    var height: CGFloat = 5
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.22))
                Capsule().fill(tint).frame(width: max(height, proxy.size.width * min(1, max(0, value))))
            }
        }
        .frame(height: height)
    }
}

struct Amount: View {
    let money: Money
    var size: CGFloat = 30
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(money.amountText).font(.system(size: size, weight: .heavy)).tracking(-size * 0.03)
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.5).widgetAccentable()
            Text(money.currency == "CREDITS" ? "credits" : money.currency).font(.system(size: max(10, size * 0.36), weight: .bold)).opacity(0.7).fixedSize()
        }
    }
}

struct Kicker: View {
    let text: String
    var dot: Color? = nil
    var body: some View {
        HStack(spacing: 5) {
            if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
            Text(text.uppercased()).font(.system(size: 9, weight: .heavy)).tracking(1).opacity(0.85).lineLimit(1)
        }
    }
}

private func relative(_ date: Date, now: Date = .now) -> String {
    let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: now), to: Calendar.current.startOfDay(for: date)).day ?? 0
    switch days {
    case ..<1: return "today"
    case 1: return "tomorrow"
    default: return "in \(days) days"
    }
}

/// Shown until the app has written its first snapshot.
public struct WidgetEmpty: View {
    public init() {}
    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AppGlyph(size: 24)
            Spacer(minLength: 0)
            Text("Open Unifai").font(.system(size: 15, weight: .bold))
            Text("Your wallets and spend appear here after the app's first refresh.").font(.system(size: 11, weight: .medium)).opacity(0.75)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct StaleNote: View {
    let snapshot: WidgetSnapshot
    var body: some View {
        if Date.now.timeIntervalSince(snapshot.generatedAt) > 6 * 3600 {
            (Text("Updated ") + Text(snapshot.generatedAt, style: .relative) + Text(" ago"))
                .font(.system(size: 9, weight: .semibold)).opacity(0.65).lineLimit(1)
        }
    }
}

// MARK: - AI spend

public struct SpendWidget: View {
    let snapshot: WidgetSnapshot
    let size: WidgetSize
    public init(snapshot: WidgetSnapshot, size: WidgetSize) { self.snapshot = snapshot; self.size = size }
    public static let colors = WidgetPalette.hero

    public var body: some View {
        Group {
            if let spend = snapshot.spend {
                if size == .small { summary(spend) }
                else {
                    HStack(alignment: .top, spacing: 18) {
                        summary(spend)
                        VStack(alignment: .leading, spacing: 10) {
                            bars(spend)
                            if let renewal = snapshot.nextRenewal { renewalRow(renewal) }
                        }
                        .frame(width: 150)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Kicker(text: "This month")
                    Spacer(minLength: 0)
                    Text("No payments yet").font(.system(size: 16, weight: .bold))
                    Text("Record or import receipts in Unifai.").font(.system(size: 11, weight: .medium)).opacity(0.75)
                }
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(URL(string: "\(WidgetLink.scheme)://payments"))
    }

    private func summary(_ spend: WidgetSnapshot.Spend) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                AppGlyph()
                Kicker(text: Date.now.formatted(.dateTime.month(.wide)))
            }
            Spacer(minLength: 6)
            Text("AI spend").font(.system(size: 11, weight: .semibold)).opacity(0.75)
            Amount(money: spend.thisMonth, size: size == .small ? 30 : 32)
            Spacer(minLength: 6)
            if let used = spend.budgetUsed, let budget = spend.budget {
                Meter(value: used, tint: used >= 1 ? WidgetPalette.negative : used >= 0.8 ? WidgetPalette.warning : WidgetPalette.lime)
                Text("\(Int((used * 100).rounded()))% of \(budget.amountText) budget").font(.system(size: 10, weight: .semibold)).opacity(0.8)
                    .lineLimit(1).padding(.top, 5)
            } else if let accruing = spend.accruing {
                Label("\(accruing.amountText) accruing", systemImage: "hourglass").font(.system(size: 10, weight: .semibold)).opacity(0.85).lineLimit(1)
            }
            StaleNote(snapshot: snapshot)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bars(_ spend: WidgetSnapshot.Spend) -> some View {
        let top = max(spend.months.max() ?? 0, 1)
        return HStack(alignment: .bottom, spacing: 7) {
            ForEach(Array(spend.months.enumerated()), id: \.offset) { index, value in
                VStack(spacing: 4) {
                    Capsule()
                        .fill(index == spend.months.count - 1 ? AnyShapeStyle(WidgetPalette.lime) : AnyShapeStyle(Color.white.opacity(0.42)))
                        .frame(height: max(4, 62 * value / top))
                    Text(spend.monthLabels.indices.contains(index) ? spend.monthLabels[index] : "")
                        .font(.system(size: 8, weight: .bold)).opacity(0.65)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 80, alignment: .bottom)
    }

    private func renewalRow(_ renewal: WidgetSnapshot.Renewal) -> some View {
        HStack(spacing: 7) {
            Logo(name: renewal.logo, size: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(renewal.name).font(.system(size: 10, weight: .bold)).lineLimit(1)
                Text("\(renewal.price.plainText) \(relative(renewal.date))").font(.system(size: 9, weight: .medium)).opacity(0.75).lineLimit(1)
            }
        }
    }
}

// MARK: - Wallets

public struct WalletsWidget: View {
    let snapshot: WidgetSnapshot
    let size: WidgetSize
    public init(snapshot: WidgetSnapshot, size: WidgetSize) { self.snapshot = snapshot; self.size = size }
    public static let colors = WidgetPalette.dark

    public var body: some View {
        let count = size == .large ? 6 : 4
        let wallets = Array(snapshot.wallets.sorted(by: Self.order).prefix(count))
        return VStack(alignment: .leading, spacing: 10) {
            if size == .large {
                HStack {
                    AppGlyph(size: 20)
                    Text("Wallets").font(.system(size: 15, weight: .bold))
                    Spacer()
                    let live = snapshot.wallets.filter { $0.status == "Live" || $0.status == "Free reset" }.count
                    Text("\(live) live").font(.system(size: 10, weight: .bold)).foregroundStyle(WidgetPalette.ink)
                        .padding(.horizontal, 7).padding(.vertical, 3).background(Capsule().fill(WidgetPalette.lime))
                }
            }
            if wallets.isEmpty {
                WidgetEmpty()
            } else if size == .small {
                compactList
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(wallets) { card($0, tall: size == .large) }
                }
            }
            if size == .large, let event = snapshot.events.first {
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Circle().fill(event.important ? WidgetPalette.lime : Color.white.opacity(0.5)).frame(width: 6, height: 6)
                    Text(event.title).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(event.date, style: .relative).font(.system(size: 9, weight: .medium)).opacity(0.6).lineLimit(1).fixedSize()
                }
                .opacity(0.9)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(URL(string: "\(WidgetLink.scheme)://wallets"))
    }

    /// Small size: a header and the top three wallets as rows.
    private var compactList: some View {
        let wallets = Array(snapshot.wallets.sorted(by: Self.order).prefix(3))
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                AppGlyph()
                Kicker(text: "Wallets")
            }
            Spacer(minLength: 0)
            ForEach(wallets) { wallet in
                HStack(spacing: 7) {
                    Logo(name: wallet.logo, size: 22)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(wallet.name).font(.system(size: 9, weight: .bold)).opacity(0.7).lineLimit(1)
                        Group {
                            if let value = wallet.value { Text(value.amountText) + Text(" " + (value.currency == "CREDITS" ? "cr" : value.currency)).font(.system(size: 8, weight: .bold)) }
                            else { Text(wallet.text ?? "") }
                        }
                        .font(.system(size: 13, weight: .heavy)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                    }
                    Spacer(minLength: 0)
                    if wallet.alert || wallet.status == "Free reset" {
                        Circle().fill(wallet.status == "Free reset" ? WidgetPalette.lime : WidgetPalette.negative).frame(width: 6, height: 6)
                    }
                }
            }
        }
    }

    /// Live wallets with a value first; manual records last.
    static func order(_ a: WidgetSnapshot.Wallet, _ b: WidgetSnapshot.Wallet) -> Bool {
        func rank(_ wallet: WidgetSnapshot.Wallet) -> Int { wallet.status == "Manual" ? 2 : (wallet.value == nil && wallet.windows.isEmpty) ? 1 : 0 }
        return rank(a) < rank(b)
    }

    private func card(_ wallet: WidgetSnapshot.Wallet, tall: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Logo(name: wallet.logo, size: tall ? 22 : 18)
                if !tall { Text(wallet.name).font(.system(size: 10, weight: .bold)).lineLimit(1).opacity(0.9) }
                Spacer(minLength: 2)
                if wallet.alert || wallet.status == "Free reset" {
                    Circle().fill(wallet.status == "Free reset" ? WidgetPalette.lime : WidgetPalette.negative).frame(width: 7, height: 7)
                }
            }
            Spacer(minLength: 2)
            if tall { Text(wallet.name).font(.system(size: 10, weight: .bold)).lineLimit(1).opacity(0.9) }
            if let window = wallet.windows.last, wallet.value == nil || tall {
                HStack(spacing: 5) {
                    Meter(value: Double(window.usedPercent) / 100, tint: window.usedPercent >= 100 ? WidgetPalette.hex(0xFFD1D1) : .white, height: 4)
                    Text("\(window.usedPercent)%").font(.system(size: 9, weight: .heavy)).monospacedDigit().fixedSize()
                }
                .padding(.vertical, 3)
            }
            if let value = wallet.value {
                Amount(money: value, size: tall ? 18 : 16)
            } else if let text = wallet.text {
                Text(text).font(.system(size: 14, weight: .heavy)).lineLimit(1).minimumScaleFactor(0.7)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: tall ? 92 : 58, maxHeight: tall ? 92 : 58, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(LinearGradient(colors: wallet.colors.prefix(2).map { WidgetPalette.hex($0) }, startPoint: .topLeading, endPoint: .bottomTrailing)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.14)))
    }
}

// MARK: - Right now

public struct RoomWidget: View {
    let snapshot: WidgetSnapshot
    let size: WidgetSize
    public init(snapshot: WidgetSnapshot, size: WidgetSize) { self.snapshot = snapshot; self.size = size }
    public static let colors = WidgetPalette.room

    public var body: some View {
        Group {
            if let best = snapshot.room.first(where: \.usable) ?? snapshot.room.first {
                if size == .small { headline(best) }
                else {
                    HStack(alignment: .top, spacing: 16) {
                        headline(best)
                        VStack(alignment: .leading, spacing: 9) {
                            ForEach(Array(snapshot.room.prefix(3).enumerated()), id: \.offset) { index, item in row(item, rank: index + 1) }
                        }
                        .frame(width: 168)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Kicker(text: "Right now", dot: WidgetPalette.lime)
                    Spacer(minLength: 0)
                    Text("No live wallets").font(.system(size: 16, weight: .bold))
                    Text("Connect Codex, OpenRouter or DeepSeek in Unifai.").font(.system(size: 11, weight: .medium)).opacity(0.75)
                }
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(URL(string: "\(WidgetLink.scheme)://timeline"))
    }

    private func headline(_ item: WidgetSnapshot.Room) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Kicker(text: "Right now", dot: WidgetPalette.lime)
            Spacer(minLength: 6)
            HStack(spacing: 6) {
                Logo(name: item.logo, size: 20)
                Text(item.name).font(.system(size: 11, weight: .bold)).lineLimit(1).opacity(0.9)
            }
            Text(item.headline).font(.system(size: 26, weight: .heavy)).tracking(-0.8).lineLimit(1).minimumScaleFactor(0.5)
                .padding(.top, 4).widgetAccentable()
            if let remaining = item.remaining {
                Meter(value: remaining, tint: remaining > 0 ? WidgetPalette.lime : WidgetPalette.hex(0xFFD1D1)).padding(.top, 6)
            }
            Spacer(minLength: 6)
            if let reset = item.nextReset, reset > .now {
                (Text("Resets in ") + Text(reset, style: .relative)).font(.system(size: 10, weight: .semibold)).opacity(0.85).lineLimit(1)
            }
            if item.freeResets > 0 {
                Label(item.freeResets == 1 ? "1 free reset" : "\(item.freeResets) free resets", systemImage: "gift.fill")
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(WidgetPalette.lime).lineLimit(1).padding(.top, 2)
            }
            StaleNote(snapshot: snapshot)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ item: WidgetSnapshot.Room, rank: Int) -> some View {
        HStack(spacing: 8) {
            Logo(name: item.logo, size: 22)
                .overlay(alignment: .topLeading) {
                    Text("\(rank)").font(.system(size: 7, weight: .heavy)).foregroundStyle(WidgetPalette.ink)
                        .frame(width: 11, height: 11).background(Circle().fill(item.usable ? WidgetPalette.lime : Color.white.opacity(0.6)))
                        .offset(x: -3, y: -3)
                }
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(item.name).font(.system(size: 10, weight: .bold)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(item.headline).font(.system(size: 10, weight: .heavy)).monospacedDigit().lineLimit(1).fixedSize()
                }
                if let remaining = item.remaining { Meter(value: remaining, tint: WidgetPalette.lime, height: 4) }
                else { Text(item.label).font(.system(size: 9, weight: .medium)).opacity(0.65).lineLimit(1) }
            }
        }
    }
}

/// URL scheme for opening the app on a page from a widget; set per channel in Info.plist.
public enum WidgetLink {
    public static var scheme: String { Bundle.main.object(forInfoDictionaryKey: "UnifaiURLScheme") as? String ?? "unifai" }
}

// MARK: - Sample data

public extension WidgetSnapshot {
    /// Synthetic values for the widget gallery before the app has written real data.
    static var sample: WidgetSnapshot {
        let now = Date.now
        return WidgetSnapshot(
            generatedAt: now,
            spend: .init(thisMonth: Money(Decimal(string: "258.93")!, "USD"), accruing: Money(Decimal(string: "17.15")!, "USD"), budget: Money(400, "USD"),
                         months: [120, 180, 95, 240, 210, 259], monthLabels: ["M", "J", "J", "A", "S", "O"], complete: true),
            nextRenewal: .init(name: "ChatGPT Plus", price: Money(20, "USD"), date: now.addingTimeInterval(4 * 86400), logo: "codex-color"),
            wallets: [
                .init(id: "1", name: "Codex", label: "Personal", logo: "codex-color", colors: [0x0A6E55, 0x12A07C, 0x3CCB9F], caption: "Codex credits",
                      value: Money(Decimal(string: "120.50")!, "CREDITS"), text: nil, windows: [.init(name: "Week", usedPercent: 68, resetsAt: now.addingTimeInterval(3 * 86400))], status: "Free reset", alert: false),
                .init(id: "2", name: "OpenRouter", label: "Personal", logo: "openrouter-color", colors: [0x4B3BE8, 0x7C4DFF, 0xC064F0], caption: "Available",
                      value: Money(70, "USD"), text: nil, windows: [], status: "Live", alert: false),
                .init(id: "3", name: "DeepSeek API", label: "Personal", logo: "deepseek-color", colors: [0x1E4FE0, 0x3D7BFF, 0x5EA0FF], caption: "Available",
                      value: Money(110, "CNY"), text: nil, windows: [], status: "Live", alert: false),
                .init(id: "4", name: "Claude", label: "Personal", logo: "claude-color", colors: [0xA8401F, 0xD8693F, 0xEE9466], caption: "Plan",
                      value: nil, text: "Claude Max", windows: [], status: "Live", alert: false),
            ],
            room: [
                .init(name: "Codex", label: "Personal", logo: "codex-color", usable: true, headline: "32% left", remaining: 0.32, nextReset: now.addingTimeInterval(3 * 3600), freeResets: 1),
                .init(name: "OpenRouter", label: "Personal", logo: "openrouter-color", usable: true, headline: "70.00 USD", remaining: nil, nextReset: nil, freeResets: 0),
                .init(name: "DeepSeek", label: "Personal", logo: "deepseek-color", usable: true, headline: "110.00 CNY", remaining: nil, nextReset: nil, freeResets: 0),
            ],
            events: [.init(title: "ChatGPT & Codex: weekly window was reset early", kind: "Early reset", date: now.addingTimeInterval(-7200), important: true)])
    }
}
