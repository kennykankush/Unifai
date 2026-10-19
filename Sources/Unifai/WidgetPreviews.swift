import SwiftUI
import UnifaiCore
import UnifaiWidgetUI

/// Renders the desktop widgets outside WidgetKit, at macOS widget sizes, for visual checks.
@MainActor enum WidgetPreviews {
    static func export(_ snapshot: WidgetSnapshot, to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sizes: [(String, WidgetSize, CGSize)] = [("small", .small, CGSize(width: 170, height: 170)),
                                                     ("medium", .medium, CGSize(width: 364, height: 170)),
                                                     ("large", .large, CGSize(width: 364, height: 382))]
        for (name, size, frame) in sizes {
            if size != .large {
                write(frame: frame, colors: RoomWidget.colors, RoomWidget(snapshot: snapshot, size: size), to: directory.appendingPathComponent("room-\(name).png"))
                write(frame: frame, colors: SpendWidget.colors, SpendWidget(snapshot: snapshot, size: size), to: directory.appendingPathComponent("spend-\(name).png"))
            }
            write(frame: frame, colors: WalletsWidget.colors, WalletsWidget(snapshot: snapshot, size: size), to: directory.appendingPathComponent("wallets-\(name).png"))
        }
    }

    private static func write<Content: View>(frame: CGSize, colors: [UInt32], _ content: Content, to url: URL) {
        let view = content
            .padding(16)
            .frame(width: frame.width, height: frame.height)
            .background(WidgetGradient(colors))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }
}
