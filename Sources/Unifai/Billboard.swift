import SwiftUI
import UnifaiCore

/// One face of the Overview billboard.
struct BoardFace: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let value: Money?
    let empty: String
    let colors: [Color]
    let caption: String
    var chip: String?
    var visual: AnyView?
    var footer: AnyView?
}

/// The Overview hero as a billboard: it rolls between faces (total spent, this month, credit left) like a
/// split-flap sign. Each face holds for `dwell` seconds; hovering pauses it, and the page marks pick a face.
/// The roll is an interruptible spring without bounce; with Reduce Motion the faces crossfade instead.
struct Billboard<Accessory: View>: View {
    let faces: [BoardFace]
    @ViewBuilder let accessory: () -> Accessory
    static var dwell: Double { 7 }

    @State private var index = AppRuntime.initialBoard ?? 0
    @State private var cycleStart = Date.now
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var face: BoardFace { faces[min(index, max(0, faces.count - 1))] }
    private var change: Animation { reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.55, bounce: 0) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ZStack {
                MeshBackdrop(colors: face.colors).id(face.id).transition(.opacity)
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    ZStack(alignment: .leading) {
                        HStack(spacing: 7) {
                            Image(systemName: face.symbol).font(.system(size: 12, weight: .bold))
                            Text(face.title).font(.system(size: 14, weight: .semibold))
                        }
                        .opacity(0.92)
                        .id(face.id).transition(roll)
                    }
                    Spacer()
                    pager
                    accessory()
                }
                Spacer(minLength: 10)
                ZStack(alignment: .bottomLeading) {
                    content(face).id(face.id).transition(roll)
                }
            }
            .padding(24)
        }
        .foregroundStyle(.white)
        .frame(height: 232)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Color.white.opacity(0.14)))
        .shadow(color: (face.colors.dropFirst().first ?? .black).opacity(0.35), radius: 24, y: 12)
        .onHover { inside in
            hovering = inside
            // A face the reader was looking at gets its full time again.
            if !inside { cycleStart = .now }
        }
        .task(id: "\(index)-\(cycleStart.timeIntervalSince1970)-\(hovering)") {
            guard faces.count > 1, !hovering else { return }
            let wait = Self.dwell - Date.now.timeIntervalSince(cycleStart)
            try? await Task.sleep(for: .seconds(max(0.1, wait)))
            guard !Task.isCancelled, !hovering else { return }
            select((index + 1) % faces.count)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(face.title)
    }

    private func select(_ next: Int) {
        withAnimation(change) { index = next }
        cycleStart = .now
    }

    /// Old face rolls up and away while the next rolls in from below, around a horizontal axis.
    private var roll: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(insertion: .modifier(active: Roll(angle: -75, offset: 26, opacity: 0), identity: Roll(angle: 0, offset: 0, opacity: 1)),
                           removal: .modifier(active: Roll(angle: 75, offset: -26, opacity: 0), identity: Roll(angle: 0, offset: 0, opacity: 1)))
    }

    private struct Roll: ViewModifier {
        let angle: Double
        let offset: CGFloat
        let opacity: Double
        func body(content: Content) -> some View {
            content
                .rotation3DEffect(.degrees(angle), axis: (x: 1, y: 0, z: 0), anchor: .center, perspective: 0.45)
                .offset(y: offset)
                .opacity(opacity)
        }
    }

    /// Page marks: the current face's mark fills linearly over its dwell time.
    private var pager: some View {
        HStack(spacing: 5) {
            ForEach(Array(faces.enumerated()), id: \.element.id) { position, item in
                Button { if position != index { select(position) } } label: {
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.32))
                        if position == index {
                            TimelineView(.animation(minimumInterval: 1 / 30, paused: hovering || reduceMotion)) { context in
                                let progress = hovering || reduceMotion ? 1 : min(1, max(0, context.date.timeIntervalSince(cycleStart) / Self.dwell))
                                Capsule().fill(Color.white).frame(width: max(6, 24 * progress))
                            }
                        }
                    }
                    .frame(width: position == index ? 24 : 6, height: 6)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(position == index ? .isSelected : [])
            }
        }
        .animation(change, value: index)
        .opacity(faces.count > 1 ? 1 : 0)
    }

    private func content(_ face: BoardFace) -> some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                if let value = face.value { MoneyText(money: value, size: 46, weight: .heavy) }
                else { Text(face.empty).font(.system(size: 38, weight: .heavy)).tracking(-1) }
                HStack(spacing: 8) {
                    if let chip = face.chip {
                        Text(chip).font(.system(size: 12, weight: .bold)).monospacedDigit()
                            .foregroundStyle(Palette.hex(0x15161B))
                            .padding(.horizontal, 9).frame(height: 24)
                            .background(Capsule().fill(Palette.lime))
                    }
                    Text(face.caption).font(.system(size: 12, weight: .medium)).opacity(0.8).lineLimit(2)
                }
                if let footer = face.footer { footer }
            }
            Spacer(minLength: 16)
            if let visual = face.visual { visual }
        }
    }
}

/// Six months of spend as capsule bars, the current month in lime.
struct MiniMonthBars: View {
    let values: [Double]
    let labels: [String]
    var body: some View {
        let top = max(values.max() ?? 0, 1)
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                VStack(spacing: 5) {
                    Capsule().fill(index == values.count - 1 ? Palette.lime : Color.white.opacity(0.4))
                        .frame(width: 18, height: max(5, 66 * value / top))
                    Text(labels.indices.contains(index) ? labels[index] : "").font(.system(size: 9, weight: .bold)).opacity(0.7)
                }
            }
        }
        .frame(height: 90, alignment: .bottom)
    }
}
