import AppKit
import Observation
import SwiftUI

/// What the menu bar item shows. Every combination is valid:
/// no metric selected shows the app symbol, and neither value nor graph shows each metric's symbol alone.
struct MenuBarContent: Equatable {
    /// The pulse as a ring filled by the averaged load of the busiest resource, with the BPM beside it when values are on.
    /// Off by default so earlier settings stay as they were.
    var pulse = false
    var memory = true
    var disk = false
    var value = true
    var graph = false
}

@MainActor
@Observable
final class MenuBarSettings {
    /// Bound to `MenuBarExtra(isInserted:)`, so ⌘-dragging the item out of the menu bar also turns this off.
    var isShown: Bool { didSet { save() } }
    var content: MenuBarContent { didSet { save() } }

    @ObservationIgnored private let defaults: UserDefaults?

    /// - Parameter defaults: `nil` keeps everything in memory (used by `--snapshot`).
    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        func flag(_ key: String, _ fallback: Bool) -> Bool { defaults?.object(forKey: key) as? Bool ?? fallback }
        let base = MenuBarContent()
        isShown = flag(Keys.shown, true)
        content = MenuBarContent(
            pulse: flag(Keys.pulse, base.pulse),
            memory: flag(Keys.memory, base.memory),
            disk: flag(Keys.disk, base.disk),
            value: flag(Keys.value, base.value),
            graph: flag(Keys.graph, base.graph)
        )
    }

    private func save() {
        guard let defaults else { return }
        defaults.set(isShown, forKey: Keys.shown)
        defaults.set(content.pulse, forKey: Keys.pulse)
        defaults.set(content.memory, forKey: Keys.memory)
        defaults.set(content.disk, forKey: Keys.disk)
        defaults.set(content.value, forKey: Keys.value)
        defaults.set(content.graph, forKey: Keys.graph)
    }

    private enum Keys {
        static let shown = "menuBar.shown"
        static let pulse = "menuBar.pulse"
        static let memory = "menuBar.memory"
        static let disk = "menuBar.disk"
        static let value = "menuBar.value"
        static let graph = "menuBar.graph"
    }
}

/// The menu bar item drawn as one template image.
/// - Important: `MenuBarExtra` labels only render text and images, so graphs must arrive as a bitmap.
///   Drawing in black and marking the image as a template lets the menu bar tint it for light, dark and highlighted states.
@MainActor
enum MenuBarGlyph {
    static let graphSamples = 30

    static func image(for content: MenuBarContent, system: SystemMonitor) -> NSImage {
        let pulse = system.vitals.isEmpty ? nil : PulseReading(loads: system.vitals.map(\.load))
        let renderer = ImageRenderer(content: GlyphView(content: content, pulse: pulse,
                                                        memory: system.memory, disk: system.disk, history: system.history))
        // The item shows on every display's menu bar, so render for the sharpest one.
        renderer.scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        let image = renderer.nsImage ?? NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: nil) ?? NSImage()
        image.isTemplate = true
        return image
    }

    static func accessibilityText(for content: MenuBarContent, system: SystemMonitor) -> String {
        let memory = system.memory, disk = system.disk
        var parts: [String] = []
        if content.pulse, !system.vitals.isEmpty {
            let pulse = PulseReading(loads: system.vitals.map(\.load))
            parts.append("맥박 \(pulse.bpm), \(pulse.mood.title)")
        }
        if content.memory, let memory {
            let percent = memory.usedFraction.formatted(.percent.precision(.fractionLength(0)))
            parts.append("메모리 \(percent) 사용" + (memory.pressure.map { ", \($0.title)" } ?? ""))
        }
        if content.disk, let disk {
            parts.append("디스크 \(disk.available.diskText) 사용 가능")
        }
        return parts.isEmpty ? "Macbak" : "Macbak, " + parts.joined(separator: " · ")
    }

    private struct GlyphView: View {
        let content: MenuBarContent
        let pulse: PulseReading?
        let memory: MemoryUsage?
        let disk: DiskUsage?
        let history: [MemorySample]

        /// The system menu bar font (13pt on macOS 27), so the item matches neighbouring text items.
        private let font = Font(NSFont.menuBarFont(ofSize: 0) as CTFont).monospacedDigit()

        var body: some View {
            HStack(spacing: 8) {
                if content.pulse { pulseSegment }
                if content.memory { memorySegment }
                if content.disk { diskSegment }
                if !content.pulse && !content.memory && !content.disk {
                    Image(systemName: "waveform.path.ecg")
                }
            }
            .font(font)
            .foregroundStyle(Color.black)
            .frame(height: 16)
            .fixedSize()
        }

        private var pulseSegment: some View {
            // The ring is the item's icon, so it shows whatever the value and graph settings are.
            HStack(spacing: 3) {
                LoadRing(load: pulse?.load)
                if content.value {
                    // Left-aligned: the ring stays next to the number; the room for a third digit trails.
                    reserved("000", pulse.map { "\($0.bpm)" } ?? "–", alignment: .leading)
                }
            }
        }

        private var memorySegment: some View {
            HStack(spacing: 3) {
                // Pressure changes the symbol itself, since a template image cannot carry color.
                Image(systemName: memory?.pressure.map { $0 == .normal ? "memorychip" : $0.symbol } ?? "memorychip")
                if content.graph {
                    Sparkline(values: sparklineValues)
                        .frame(width: 28, height: 13)
                }
                if content.value {
                    reserved("00%", memory?.usedFraction.formatted(.percent.precision(.fractionLength(0))) ?? "–")
                }
            }
        }

        private var diskSegment: some View {
            HStack(spacing: 3) {
                Image(systemName: "internaldrive")
                if content.graph {
                    CapacityBar(fraction: disk?.usedFraction ?? 0)
                        .frame(width: 22, height: 10)
                }
                if content.value {
                    reserved("000GB", disk.map { compactBytes($0.available) } ?? "–")
                }
            }
        }

        private var sparklineValues: [Double] {
            guard let physical = memory?.physical, physical > 0 else { return [] }
            return history.suffix(MenuBarGlyph.graphSamples).map { min(Double($0.used) / Double(physical), 1) }
        }

        /// Reserves the usual width (digits are monospaced) so the item does not shift as the number changes.
        /// Rarer wider values such as "100%" still fit, at the cost of one shift.
        private func reserved(_ usual: String, _ text: String, alignment: Alignment = .trailing) -> some View {
            ZStack(alignment: alignment) {
                Text(usual).hidden()
                Text(text)
            }
        }

        /// "479GB" or "1.2TB": no space, so the menu bar item stays narrow.
        private func compactBytes(_ bytes: Int64) -> String {
            let gb = Double(bytes) / 1_000_000_000
            return gb >= 1000
                ? (gb / 1000).formatted(.number.precision(.fractionLength(1))) + "TB"
                : gb.formatted(.number.precision(.fractionLength(0))) + "GB"
        }
    }

    /// Used memory over the last minute on a fixed 0–100% scale, drawn as a level inside a frame:
    /// a steady value still reads as "this full", and changes show as the surface moving. New samples enter from the right.
    private struct Sparkline: View {
        let values: [Double]

        var body: some View {
            ZStack {
                RoundedRectangle(cornerRadius: 2.5, style: .continuous).stroke(Color.black, lineWidth: 1)
                GeometryReader { geo in
                    let points = Self.points(values, in: geo.size)
                    if let first = points.first, let last = points.last {
                        Path { path in
                            path.move(to: CGPoint(x: first.x, y: geo.size.height))
                            points.forEach { path.addLine(to: $0) }
                            path.addLine(to: CGPoint(x: last.x, y: geo.size.height))
                            path.closeSubpath()
                        }
                        .fill(Color.black.opacity(0.3))
                        Path { path in path.addLines(points) }
                            .stroke(Color.black, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                    }
                }
                .padding(1.5)
                .clipShape(RoundedRectangle(cornerRadius: 1.5, style: .continuous))
            }
        }

        static func points(_ values: [Double], in size: CGSize) -> [CGPoint] {
            let slots = max(MenuBarGlyph.graphSamples - 1, 1)
            let step = size.width / CGFloat(slots)
            let start = CGFloat(slots - (values.count - 1)) * step
            return values.enumerated().map { index, value in
                CGPoint(x: start + CGFloat(index) * step, y: size.height - CGFloat(value) * (size.height - 1))
            }
        }
    }

    /// The pulse's load as a ring that fills clockwise from the top, over a faint track; the track alone before any sample.
    /// Both strokes are inset by half the line, so the ring stays inside the 16pt item.
    private struct LoadRing: View {
        let load: Double?
        private let line: CGFloat = 2.6

        var body: some View {
            ZStack {
                Circle().inset(by: line / 2).stroke(Color.black.opacity(0.3), lineWidth: line)
                if let load {
                    Circle().inset(by: line / 2).trim(from: 0, to: min(max(load, 0), 1))
                        .stroke(Color.black, style: StrokeStyle(lineWidth: line, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
            }
            .frame(width: 14, height: 14)
        }
    }

    private struct CapacityBar: View {
        let fraction: Double

        var body: some View {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2.5, style: .continuous).stroke(Color.black, lineWidth: 1)
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .frame(width: max((geo.size.width - 3) * min(fraction, 1), 0))
                        .padding(1.5)
                }
            }
        }
    }
}
