import AppKit
import SwiftUI

/// The Mac's "pulse": how hard it is working, as a heart rate from 60 BPM (resting) to 120 BPM (one resource maxed out).
/// The load of a sample is its busiest resource — CPU, GPU or memory pressure — see `VitalSample.load`.
/// - Note: A metaphor for the glance. The meters beside it always show the real values and which one sets the pace.
/// - Important: Calm on purpose. The load is averaged (about a 10-second time constant at 2-second samples), and each
///   mood has a gap between entering and leaving it, so a one-sample spike neither jumps the rate nor flips the mood.
struct PulseReading: Equatable {
    enum Mood {
        case calm, busy, racing
    }

    static let smoothing = 0.2
    /// Enter and leave thresholds for each mood, on the averaged load.
    static let busyBand = (enter: 0.3, leave: 0.2)
    static let racingBand = (enter: 0.65, leave: 0.5)

    /// Averaged load, 0...1.
    let load: Double
    let mood: Mood

    /// - Parameter loads: load per sample, oldest first. Folded from the start each time, so the reading needs no
    ///   stored state and the same history always gives the same reading. The average starts from rest, so the app's
    ///   own launch work in the first sample does not open on a racing heart.
    init(loads: [Double]) {
        var average = 0.0
        var mood = Mood.calm
        for raw in loads {
            average += Self.smoothing * (min(max(raw, 0), 1) - average)
            mood = Self.mood(after: mood, at: average)
        }
        load = average
        self.mood = mood
    }

    private static func mood(after previous: Mood, at load: Double) -> Mood {
        switch previous {
        case .calm: load >= racingBand.enter ? .racing : load >= busyBand.enter ? .busy : .calm
        case .busy: load >= racingBand.enter ? .racing : load < busyBand.leave ? .calm : .busy
        case .racing: load >= racingBand.leave ? .racing : load < busyBand.leave ? .calm : .busy
        }
    }

    var bpm: Int { Int((60 + load * 60).rounded()) }

    static let explanation = "맥박은 CPU, GPU, 메모리 압력 중 가장 바쁜 자원의 최근 평균 부하를 박동수로 바꾼 값입니다. 모두 쉬면 60, 하나라도 꽉 차면 120입니다. 메모리는 압력이 보통이면 절반만 반영합니다."
}

extension PulseReading.Mood {
    var title: String {
        switch self {
        case .calm: "평온해요"
        case .busy: "조금 바빠요"
        case .racing: "숨이 차요"
        }
    }

    /// The runner for each mood: a plodding tortoise, a hopping hare, a sprinting hare — the speed slider's animals.
    var runner: (symbol: String, stride: Double, hop: CGFloat, groundSpeed: CGFloat) {
        switch self {
        case .calm: ("tortoise.fill", 0.9, 1.5, 10)
        case .busy: ("hare.fill", 0.42, 6, 60)
        case .racing: ("hare.fill", 0.26, 8, 150)
        }
    }
}

/// One beat per sample, run by Core Animation: a heart that bounces, or the trace head's ring that swells and fades.
/// Still under Reduce Motion.
/// - Important: The SwiftUI versions (a symbol effect, scale and opacity animations) re-rendered the whole card on the
///   CPU for every frame of every beat. Here the app hands one animation to Core Animation per sample, and the render
///   server plays it.
struct Beat: NSViewRepresentable {
    enum Style {
        case heart, ring
    }

    let style: Style
    let trigger: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> BeatView { BeatView(style: style) }

    func updateNSView(_ view: BeatView, context: Context) {
        view.beat(trigger, animated: !reduceMotion)
    }
}

final class BeatView: NSView {
    private let style: Beat.Style
    private let mark = CALayer()
    private let ring = CALayer()
    private var lastTrigger: Int?

    init(style: Beat.Style) {
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true
        mark.contentsGravity = .resizeAspect
        ring.opacity = 0
        layer?.addSublayer(ring)
        layer?.addSublayer(mark)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        mark.contentsScale = window?.backingScaleFactor ?? 2
    }

    private func paint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            switch style {
            case .heart:
                let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular).applying(NSImage.SymbolConfiguration(paletteColors: [.systemPink]))
                mark.contents = NSImage(systemSymbolName: "heart.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config)
            case .ring:
                mark.backgroundColor = NSColor.systemPink.cgColor
                ring.backgroundColor = NSColor.systemPink.withAlphaComponent(0.4).cgColor
            }
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mark.frame = bounds
        ring.frame = bounds
        if style == .ring {
            mark.cornerRadius = bounds.width / 2
            ring.cornerRadius = bounds.width / 2
        }
        CATransaction.commit()
    }

    func beat(_ trigger: Int, animated: Bool) {
        defer { lastTrigger = trigger }
        guard animated, let lastTrigger, lastTrigger != trigger else { return }
        switch style {
        case .heart:
            let bounce = CAKeyframeAnimation(keyPath: "transform.scale")
            bounce.values = [1, 1.28, 0.94, 1]
            bounce.keyTimes = [0, 0.3, 0.65, 1]
            bounce.duration = 0.45
            mark.add(bounce, forKey: "beat")
        case .ring:
            let swell = CABasicAnimation(keyPath: "transform.scale")
            swell.fromValue = 1
            swell.toValue = 2.6
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.9
            fade.toValue = 0
            let group = CAAnimationGroup()
            group.animations = [swell, fade]
            group.duration = 0.7
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ring.add(group, forKey: "beat")
        }
    }
}

/// Load history drawn as a heart monitor: one beat per sample, each spike as tall as that sample's load. The trace glides
/// left continuously and the ring at the head swells on each beat, both played by Core Animation (`LiveLine`, `Beat`).
struct HeartbeatTrace: View {
    let samples: [VitalSample]
    var beats = 30
    var height: CGFloat = 96
    var tint: Color = .pink

    private var baseline: CGFloat { height * 0.68 }

    var body: some View {
        LiveLine(values: samples.suffix(beats + 1).map(\.load), sampleID: samples.last?.id ?? 0,
                 style: .heartbeat(beats: beats, baseline: baseline), tint: tint, lineWidth: 1.8, fadesLeadingEdge: true)
        .overlay(alignment: .topTrailing) {
            Beat(style: .ring, trigger: samples.last?.id ?? 0)
                .frame(width: 7, height: 7)
                .offset(x: 3.5, y: baseline - 3.5)
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("부하 변화")
        .accessibilityValue(samples.last.map { "현재 \(($0.load * 100).percentText)" } ?? "")
    }

}

/// The heart-monitor line, shared by the glance trace and the menu bar glyph.
enum PulseLine {
    /// - Parameters:
    ///   - loads: one beat per value, oldest first; slots without a value on the left stay flat.
    ///   - baseline: the flat line's height from the top; spikes rise above it.
    static func path(loads: [Double], beats: Int, in size: CGSize, baseline: CGFloat) -> Path {
        let slot = size.width / CGFloat(max(beats, 1))
        let start = CGFloat(max(beats - loads.count, 0)) * slot
        var path = Path()
        path.move(to: CGPoint(x: 0, y: baseline))
        path.addLine(to: CGPoint(x: start, y: baseline))
        for (index, load) in loads.suffix(beats).enumerated() {
            addBeat(to: &path, at: start + CGFloat(index) * slot, width: slot, load: load, baseline: baseline)
        }
        return path
    }

    /// One P-QRS-T complex, at fixed fractions of its slot. The spike height follows the load, with a floor so idle still beats.
    private static func addBeat(to path: inout Path, at x: CGFloat, width: CGFloat, load: Double, baseline y: CGFloat) {
        let amplitude = (0.16 + 0.84 * CGFloat(min(max(load, 0), 1))) * (y - 1)
        path.addLine(to: CGPoint(x: x + width * 0.16, y: y))
        path.addQuadCurve(to: CGPoint(x: x + width * 0.3, y: y), control: CGPoint(x: x + width * 0.23, y: y - amplitude * 0.16))
        path.addLine(to: CGPoint(x: x + width * 0.38, y: y + amplitude * 0.1))
        path.addLine(to: CGPoint(x: x + width * 0.46, y: y - amplitude))
        path.addLine(to: CGPoint(x: x + width * 0.54, y: y + amplitude * 0.22))
        path.addLine(to: CGPoint(x: x + width * 0.62, y: y))
        path.addQuadCurve(to: CGPoint(x: x + width * 0.86, y: y), control: CGPoint(x: x + width * 0.74, y: y - amplitude * 0.22))
        path.addLine(to: CGPoint(x: x + width, y: y))
    }
}

/// CPU, GPU and memory side by side; the one setting the pace carries the heart.
struct VitalMeters: View {
    let sample: VitalSample?
    let pressure: MemoryPressure?
    var minimumColumnWidth: CGFloat = 110

    var body: some View {
        AdaptiveGrid(minimumColumnWidth: minimumColumnWidth, maximumColumns: 3, spacing: 16) {
            ForEach(VitalSample.Vital.allCases, id: \.self) { vital in
                meter(vital)
            }
        }
    }

    /// Name, then the number, then the bar — stacked, so a narrow column (the menu bar panel's is about 90pt) never wraps.
    /// The number changes at once, like Activity Monitor; the bar beneath glides (in Core Animation, see `MeterBar`).
    private func meter(_ vital: VitalSample.Vital) -> some View {
        let value = sample?.value(of: vital)
        let leads = sample?.leader == vital && value != nil
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(vital.title).font(.callout.weight(.medium)).foregroundStyle(.secondary)
                if leads {
                    Image(systemName: "heart.fill").font(.caption).foregroundStyle(.pink).accessibilityLabel("맥박을 정하는 자원")
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value.map { ($0 * 100).percentText } ?? "–")
                    .font(Theme.numeral(18))
                    .monospacedDigit()
                if vital == .memory, value != nil, let pressure {
                    Text(pressure.shortTitle).font(.callout).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            MeterBar(fraction: value ?? 0, tint: leads ? .pink : Color.secondary.opacity(0.6))
        }
        .accessibilityElement(children: .combine)
        .help(vital == .memory ? "메모리 압력: 100 − macOS가 사용 가능하다고 보는 메모리 비율. 압력이 보통이면 맥박에는 절반만 반영합니다." : "")
    }
}

/// A runner over moving ground whose pace follows the pulse, like the horse on an old taxi meter.
/// - Important: Core Animation runs the motion in the render server, so it costs the app nothing per frame. The same
///   motion in SwiftUI would re-render the whole card on the CPU every frame.
struct PaceRunner: NSViewRepresentable {
    let mood: PulseReading.Mood
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> PaceRunnerView { PaceRunnerView() }

    func updateNSView(_ view: PaceRunnerView, context: Context) {
        view.show(mood, moving: !reduceMotion)
    }
}

final class PaceRunnerView: NSView {
    private static let dashSpacing: CGFloat = 14
    private static let animalHeight: CGFloat = 24

    private let ground = CAReplicatorLayer()
    private let dash = CALayer()
    private let animal = CALayer()
    private var mood: PulseReading.Mood?
    private var moving = true

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        dash.cornerRadius = 1
        ground.addSublayer(dash)
        ground.instanceTransform = CATransform3DMakeTranslation(Self.dashSpacing, 0, 0)
        animal.contentsGravity = .resizeAspect
        layer?.addSublayer(ground)
        layer?.addSublayer(animal)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.animalHeight + 14) }

    func show(_ mood: PulseReading.Mood, moving: Bool) {
        guard mood != self.mood || moving != self.moving else { return }
        let symbolChanged = mood.runner.symbol != self.mood?.runner.symbol
        self.mood = mood
        self.moving = moving
        if symbolChanged { paint() }
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        animal.contentsScale = window?.backingScaleFactor ?? 2
    }

    /// Resolves the symbol and dash colors for the current appearance.
    private func paint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            dash.backgroundColor = NSColor.tertiaryLabelColor.cgColor
            let config = NSImage.SymbolConfiguration(pointSize: Self.animalHeight, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.secondaryLabelColor]))
            animal.contents = NSImage(systemSymbolName: mood?.runner.symbol ?? "tortoise.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
        }
    }

    override func layout() {
        super.layout()
        guard let mood else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dash.frame = CGRect(x: 0, y: 2, width: 6, height: 2)
        ground.frame = CGRect(x: 0, y: 0, width: bounds.width + Self.dashSpacing * 2, height: 6)
        ground.instanceCount = Int(ground.frame.width / Self.dashSpacing) + 1
        let size = (animal.contents as? NSImage)?.size ?? CGSize(width: Self.animalHeight, height: Self.animalHeight)
        let width = Self.animalHeight * size.width / max(size.height, 1)
        animal.frame = CGRect(x: (bounds.width - width) * 0.4, y: 7, width: width, height: Self.animalHeight)
        CATransaction.commit()

        animal.removeAllAnimations()
        ground.removeAllAnimations()
        guard moving else { return }
        let pace = mood.runner
        let hop = CAKeyframeAnimation(keyPath: "position.y")
        hop.values = [animal.position.y, animal.position.y + pace.hop, animal.position.y]
        hop.keyTimes = [0, 0.5, 1]
        hop.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeIn)]
        hop.duration = pace.stride
        hop.repeatCount = .infinity
        animal.add(hop, forKey: "hop")

        // The animals face right, so the ground runs left.
        let scroll = CABasicAnimation(keyPath: "position.x")
        scroll.fromValue = ground.position.x
        scroll.toValue = ground.position.x - Self.dashSpacing
        scroll.duration = Self.dashSpacing / pace.groundSpeed
        scroll.repeatCount = .infinity
        ground.add(scroll, forKey: "scroll")
    }
}
