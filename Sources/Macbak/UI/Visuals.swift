import SwiftUI

/// Status is never color alone: the symbol and the label carry it, the tint only reinforces.
struct StatusTag: View {
    let title: String
    let symbol: String
    let tint: Color

    var body: some View {
        Label {
            Text(title).foregroundStyle(.primary)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .contentTransition(.symbolEffect(.replace))
    }
}

extension StatusTag {
    init(_ status: CleanupStatus) { self.init(title: status.title, symbol: status.symbol, tint: status.tint) }
    init(_ pressure: MemoryPressure) { self.init(title: pressure.title, symbol: pressure.symbol, tint: pressure.tint) }
}

/// A big number over its caption.
struct MetricView: View {
    let value: String
    let caption: String
    var size: CGFloat = 28

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            RollingText(text: value, size: size)
            Text(caption).font(.callout).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

/// "3초 전 · 2초마다": how fresh a live value is, so a stalled reading never looks current.
struct Freshness: View {
    let date: Date?
    let cadence: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(label(now: context.date)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private func label(now: Date) -> String {
        guard let date else { return "읽는 중 · \(cadence)" }
        return "\(max(Int(now.timeIntervalSince(date)), 0))초 전 · \(cadence)"
    }
}

// MARK: - Gauges

struct RingCenter: View {
    let value: String
    let caption: String

    var body: some View {
        VStack(spacing: 1) {
            Text(value)
                .font(Theme.numeral(20))
                .monospacedDigit()
            Text(caption).font(.callout).foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .padding(.horizontal, 14)
    }
}

/// Diagonal texture for "projected" values, so they never rely on color alone.
struct Stripes: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            var x = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 6
            }
            context.stroke(path, with: .color(.white.opacity(0.6)), lineWidth: 1.5)
        }
    }
}

struct LegendRow: View {
    let swatch: AnyShapeStyle
    var striped = false
    let title: String
    let value: String
    var note: String?

    init<S: ShapeStyle>(_ swatch: S, striped: Bool = false, title: String, value: String, note: String? = nil) {
        self.swatch = AnyShapeStyle(swatch)
        self.striped = striped
        self.title = title
        self.value = value
        self.note = note
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(swatch)
                .overlay {
                    if striped { Stripes().clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous)) }
                }
                .frame(width: 10, height: 10)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                if let note {
                    Text(note).font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            Text(value).font(.body.monospacedDigit())
        }
    }
}

/// A small trend line with no axes that glides left between samples (see `LiveLine`).
/// - Parameters:
///   - sampleID: changes once per sample and starts the next glide.
///   - capacity: fixed slots, so a short history grows in from the right like a monitor.
struct Sparkline: View {
    let values: [Double]
    let sampleID: Int
    var ceiling: Double?
    var capacity: Int?
    var tint: Color = .blue

    var body: some View {
        LiveLine(values: values, sampleID: sampleID, style: .sparkline(slots: capacity ?? max(values.count, 2), ceiling: ceiling), tint: tint)
            .accessibilityHidden(true)
    }
}
