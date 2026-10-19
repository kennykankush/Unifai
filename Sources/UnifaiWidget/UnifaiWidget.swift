import SwiftUI
import WidgetKit
import UnifaiCore
import UnifaiWidgetUI

// Unifai's desktop widgets. The extension is sandboxed and reads only the snapshot the app writes
// to the shared app group container; it has no credentials and makes no network requests.

struct Entry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: .now, snapshot: .sample) }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: .now, snapshot: WidgetStore.load() ?? (context.isPreview ? .sample : nil)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        // The app reloads widgets when its data changes; this keeps relative times honest in between.
        let entry = Entry(date: .now, snapshot: WidgetStore.load())
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(30 * 60))))
    }
}

private extension WidgetFamily {
    var size: WidgetSize {
        switch self {
        case .systemSmall: return .small
        case .systemLarge, .systemExtraLarge: return .large
        default: return .medium
        }
    }
}

private struct Container<Content: View>: View {
    let colors: [UInt32]
    let snapshot: WidgetSnapshot?
    @ViewBuilder let content: (WidgetSnapshot) -> Content
    var body: some View {
        Group {
            if let snapshot { content(snapshot) } else { WidgetEmpty() }
        }
        .containerBackground(for: .widget) { WidgetGradient(colors) }
    }
}

struct SpendWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry
    var body: some View {
        Container(colors: SpendWidget.colors, snapshot: entry.snapshot) { SpendWidget(snapshot: $0, size: family.size) }
    }
}

struct WalletsWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry
    var body: some View {
        Container(colors: WalletsWidget.colors, snapshot: entry.snapshot) { WalletsWidget(snapshot: $0, size: family.size) }
    }
}

struct RoomWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry
    var body: some View {
        Container(colors: RoomWidget.colors, snapshot: entry.snapshot) { RoomWidget(snapshot: $0, size: family.size) }
    }
}

struct SpendWidgetConfiguration: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "UnifaiSpend", provider: Provider()) { SpendWidgetEntryView(entry: $0) }
            .configurationDisplayName("AI Spend")
            .description("This month's AI and cloud spend, your budget and the next renewal.")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct WalletsWidgetConfiguration: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "UnifaiWallets", provider: Provider()) { WalletsWidgetEntryView(entry: $0) }
            .configurationDisplayName("Wallets")
            .description("Balances, plans and usage limits across your AI wallets.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct RoomWidgetConfiguration: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "UnifaiRoom", provider: Provider()) { RoomWidgetEntryView(entry: $0) }
            .configurationDisplayName("Right Now")
            .description("Which wallet has room for heavy work, when limits reset and any free resets.")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct UnifaiWidgets: WidgetBundle {
    var body: some Widget {
        RoomWidgetConfiguration()
        SpendWidgetConfiguration()
        WalletsWidgetConfiguration()
    }
}
