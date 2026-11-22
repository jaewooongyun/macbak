import AppKit
import SwiftUI

/// Bars and rings that glide to each new sample in Core Animation.
/// - Important: The same glide as a SwiftUI animation redrew the surrounding card on the CPU for every frame, on every
///   2-second sample; here the app sets the new value once and the render server plays the motion.

/// A value against the largest in its list, as a capsule that fills from the left.
struct MeterBar: View {
    let fraction: Double
    var tint: Color = .blue

    var body: some View {
        MeterBarLayer(fraction: fraction, tint: tint).frame(height: 8)
    }
}

private struct MeterBarLayer: NSViewRepresentable {
    let fraction: Double
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> MeterBarView { MeterBarView() }

    func updateNSView(_ view: MeterBarView, context: Context) {
        view.set(fraction: fraction, tint: NSColor(tint), animated: !reduceMotion)
    }
}

final class MeterBarView: LiveShapeView {
    private let track = CALayer()
    private let fill = CALayer()
    private var fraction = 0.0
    private var tint = NSColor.systemBlue

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.addSublayer(track)
        layer?.addSublayer(fill)
    }

    required init?(coder: NSCoder) { nil }

    func set(fraction: Double, tint: NSColor, animated: Bool) {
        let clamped = min(max(fraction, 0), 1)
        let changed = (clamped * 100).rounded() != (self.fraction * 100).rounded()
        self.fraction = clamped
        self.tint = tint
        paint()
        if changed { glide(animated: animated) { self.place() } }
    }

    override func paint() {
        resolve {
            track.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            fill.backgroundColor = tint.cgColor
        }
    }

    override func layout() {
        super.layout()
        still { place() }
    }

    private func place() {
        let radius = bounds.height / 2
        track.frame = bounds
        track.cornerRadius = radius
        fill.frame = CGRect(x: 0, y: 0, width: max(bounds.width * fraction, bounds.height * 0.75), height: bounds.height)
        fill.cornerRadius = radius
    }
}

/// A ring that fills clockwise from the top, with SwiftUI content in the middle. It springs from empty when it appears.
struct RingGauge<Center: View>: View {
    let fraction: Double
    let tint: Color
    var lineWidth: CGFloat = 12
    @ViewBuilder let center: Center

    var body: some View {
        ZStack {
            RingLayer(fraction: fraction, tint: tint, lineWidth: lineWidth)
            center
        }
    }
}

private struct RingLayer: NSViewRepresentable {
    let fraction: Double
    let tint: Color
    let lineWidth: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.arrivesInPlace) private var arrivesInPlace

    func makeNSView(context: Context) -> RingView { RingView(reveals: !arrivesInPlace) }

    func updateNSView(_ view: RingView, context: Context) {
        view.set(fraction: fraction, tint: NSColor(tint), lineWidth: lineWidth, animated: !reduceMotion)
    }
}

final class RingView: LiveShapeView {
    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()
    private var fraction = 0.0
    private var tint = NSColor.systemBlue
    private var revealed = false
    private let reveals: Bool

    init(reveals: Bool) {
        self.reveals = reveals
        super.init(frame: .zero)
        for shape in [track, arc] {
            shape.fillColor = nil
            shape.lineCap = .round
            layer?.addSublayer(shape)
        }
        arc.strokeEnd = 0
    }

    required init?(coder: NSCoder) { nil }

    func set(fraction: Double, tint: NSColor, lineWidth: CGFloat, animated: Bool) {
        let clamped = max(min(fraction, 1), 0.002)
        let changed = (clamped * 100).rounded() != (self.fraction * 100).rounded()
        self.fraction = clamped
        self.tint = tint
        track.lineWidth = lineWidth
        arc.lineWidth = lineWidth
        paint()
        if revealed {
            if changed { glide(animated: animated) { self.arc.strokeEnd = clamped } }
        } else {
            revealIfNeeded()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        revealIfNeeded()
    }

    override func paint() {
        resolve {
            track.strokeColor = NSColor.quaternaryLabelColor.cgColor
            arc.strokeColor = tint.cgColor
        }
    }

    override func layout() {
        super.layout()
        let side = min(bounds.width, bounds.height) - track.lineWidth
        guard side > 0 else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let path = CGMutablePath()
        // Unflipped view: angles grow counterclockwise, so start at the top and go clockwise.
        path.addArc(center: center, radius: side / 2, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        still {
            track.frame = bounds
            arc.frame = bounds
            track.path = path
            arc.path = path
        }
        revealIfNeeded()
    }

    /// The first fill springs from empty, once the ring is in a window and has a size. Layout, joining a window and a
    /// new value can come in any order, so each of them asks.
    private func revealIfNeeded() {
        guard !revealed, window != nil, arc.path != nil else { return }
        revealed = true
        guard reveals, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            still { arc.strokeEnd = fraction }
            return
        }
        let spring = CASpringAnimation(keyPath: "strokeEnd")
        spring.fromValue = 0
        spring.toValue = fraction
        spring.damping = 16
        spring.stiffness = 170
        spring.duration = spring.settlingDuration
        still { arc.strokeEnd = fraction }
        arc.add(spring, forKey: "reveal")
    }
}

/// Shared plumbing: a layer-backed, unflipped view that resolves colors for its appearance and glides layer changes.
class LiveShapeView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    /// Re-resolves dynamic colors (light, dark, Increase Contrast).
    func paint() {}

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    func resolve(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance(body)
        CATransaction.commit()
    }

    func still(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    /// Same length and curve as SwiftUI's `Theme.liveChange`, so layer and view changes move together.
    func glide(animated: Bool, _ body: @escaping () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated || window == nil)
        CATransaction.setAnimationDuration(0.22)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        body()
        CATransaction.commit()
    }
}

// MARK: - Rolling number

extension Theme {
    /// AppKit twin of `Theme.numeral`: SF Pro Rounded, semibold, monospaced digits.
    static func numeralFont(_ size: CGFloat) -> NSFont {
        let base = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold)
        return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
    }
}

/// A number that rolls to each new value: the new text pushes in from below when it grows and from above when it shrinks.
/// - Important: A Core Animation push, so the app draws the new text once. SwiftUI's `numericText` transition redrew the
///   card for every frame and, with the other live values, kept the glance screen near a third of a core.
struct RollingText: View {
    let text: String
    /// Sets the roll direction; nil always rolls up.
    var value: Double?
    var size: CGFloat
    var secondary = false

    var body: some View {
        let font = Theme.numeralFont(size)
        let baseline = ceil(font.ascender)
        RollingTextLayer(text: text, value: value, font: font, secondary: secondary)
            .fixedSize()
            .alignmentGuide(.firstTextBaseline) { _ in baseline }
            .alignmentGuide(.lastTextBaseline) { _ in baseline }
            .accessibilityElement()
            .accessibilityLabel(text)
    }
}

private struct RollingTextLayer: NSViewRepresentable {
    let text: String
    let value: Double?
    let font: NSFont
    let secondary: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> RollingTextView { RollingTextView() }

    func updateNSView(_ view: RollingTextView, context: Context) {
        view.set(text, value: value, font: font, color: secondary ? .secondaryLabelColor : .labelColor, animated: !reduceMotion)
    }
}

final class RollingTextView: LiveShapeView {
    private let label = CATextLayer()
    private var text = ""
    private var value: Double?
    private var font = NSFont.systemFont(ofSize: 13)
    private var color = NSColor.labelColor

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.masksToBounds = true
        label.alignmentMode = .left
        label.truncationMode = .none
        layer?.addSublayer(label)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        let size = (text as NSString).size(withAttributes: [.font: font])
        return NSSize(width: ceil(size.width), height: ceil(font.ascender - font.descender))
    }

    func set(_ new: String, value newValue: Double?, font newFont: NSFont, color newColor: NSColor, animated: Bool) {
        let changed = new != text
        let up = (newValue ?? 0) >= (value ?? 0)
        let first = text.isEmpty
        text = new
        value = newValue
        font = newFont
        color = newColor
        paint()
        invalidateIntrinsicContentSize()
        if changed, animated, !first, window != nil {
            let roll = CATransition()
            roll.type = .push
            roll.subtype = up ? .fromBottom : .fromTop
            roll.duration = 0.22
            roll.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            label.add(roll, forKey: "roll")
        }
        still { label.string = NSAttributedString(string: new, attributes: [.font: font, .foregroundColor: resolved(color)]) }
    }

    override func paint() {
        still {
            label.contentsScale = window?.backingScaleFactor ?? 2
            label.string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: resolved(color)])
        }
    }

    private func resolved(_ color: NSColor) -> NSColor {
        var cg = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { cg = color.cgColor }
        return NSColor(cgColor: cg) ?? color
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        paint()
    }

    override func layout() {
        super.layout()
        still { label.frame = bounds }
    }
}

// MARK: - Segment bar

struct BarSegment: Identifiable {
    let id: String
    let value: Double
    let color: Color
    var striped = false

    init(_ id: String, _ value: Double, _ color: Color, striped: Bool = false) {
        self.id = id
        self.value = value
        self.color = color
        self.striped = striped
    }
}

extension Color {
    /// Label-hierarchy fills as plain colors, for places that need a `Color` (Core Animation layers).
    static let fillSecondary = Color(nsColor: .secondaryLabelColor)
    static let fillTertiary = Color(nsColor: .tertiaryLabelColor)
    static let fillQuaternary = Color(nsColor: .quaternaryLabelColor)
}

/// Part-to-whole bar: 2pt gaps between segments, revealed left to right on first appear, gliding as the parts change.
struct SegmentBar: View {
    let segments: [BarSegment]
    var height: CGFloat = 20
    /// Off for surfaces that open often, like the menu bar panel, where a reveal would only slow the glance.
    var revealOnAppear = true

    var body: some View {
        SegmentBarLayer(segments: segments, revealOnAppear: revealOnAppear).frame(height: height)
    }
}

private struct SegmentBarLayer: NSViewRepresentable {
    let segments: [BarSegment]
    let revealOnAppear: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.arrivesInPlace) private var arrivesInPlace

    func makeNSView(context: Context) -> SegmentBarView { SegmentBarView(reveals: revealOnAppear && !arrivesInPlace) }

    func updateNSView(_ view: SegmentBarView, context: Context) {
        view.set(segments.map { .init(id: $0.id, value: max($0.value, 0), color: NSColor($0.color), striped: $0.striped) }, animated: !reduceMotion)
    }
}

final class SegmentBarView: LiveShapeView {
    struct Part: Equatable {
        let id: String
        let value: Double
        let color: NSColor
        let striped: Bool
    }

    private static let gap: CGFloat = 2
    private static let stripeTile: NSImage = {
        NSImage(size: NSSize(width: 6, height: 6), flipped: false) { rect in
            let line = NSBezierPath()
            line.move(to: NSPoint(x: -1, y: -1))
            line.line(to: NSPoint(x: rect.width + 1, y: rect.height + 1))
            line.lineWidth = 1.5
            NSColor.white.withAlphaComponent(0.6).setStroke()
            line.stroke()
            return true
        }
    }()

    private var parts: [Part] = []
    private var layers: [String: (fill: CALayer, stripes: CALayer)] = [:]
    private let reveal = CALayer()
    private let reveals: Bool
    private var revealed = false

    init(reveals: Bool) {
        self.reveals = reveals
        super.init(frame: .zero)
        reveal.backgroundColor = NSColor.black.cgColor
        layer?.mask = reveal
    }

    required init?(coder: NSCoder) { nil }

    func set(_ new: [Part], animated: Bool) {
        let before = percents(parts)
        // A new part starts with no size, so a change of parts is placed even when every share stays the same.
        let regrouped = parts.map(\.id) != new.map(\.id)
        parts = new
        // A part that left keeps no layer, or its last frame would stay drawn over the bar.
        let ids = Set(new.map(\.id))
        for (id, gone) in layers where !ids.contains(id) {
            gone.fill.removeFromSuperlayer()
            layers[id] = nil
        }
        for part in new where layers[part.id] == nil {
            let fill = CALayer(), stripes = CALayer()
            stripes.backgroundColor = NSColor(patternImage: Self.stripeTile).cgColor
            fill.addSublayer(stripes)
            fill.masksToBounds = true
            layer?.addSublayer(fill)
            layers[part.id] = (fill, stripes)
        }
        paint()
        if regrouped || percents(new) != before { glide(animated: animated) { self.place() } }
    }

    /// Whole-percent shares, so fractions of a percent on every sample do not move anything.
    private func percents(_ parts: [Part]) -> [Double] {
        let total = max(parts.reduce(0) { $0 + $1.value }, 1)
        return parts.map { ($0.value / total * 100).rounded() }
    }

    override func paint() {
        resolve {
            for part in parts {
                layers[part.id]?.fill.backgroundColor = part.color.cgColor
                layers[part.id]?.stripes.isHidden = !part.striped
            }
        }
    }

    override func layout() {
        super.layout()
        still { place() }
        revealIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        revealIfNeeded()
    }

    private func place() {
        let visible = parts.filter { $0.value > 0 }
        let total = max(visible.reduce(0) { $0 + $1.value }, 1)
        let usable = max(bounds.width - CGFloat(max(visible.count - 1, 0)) * Self.gap, 0)
        let radius = min(bounds.height / 2, 6)
        var x: CGFloat = 0
        for part in parts {
            guard let pair = layers[part.id] else { continue }
            let width = part.value > 0 ? usable * part.value / total : 0
            pair.fill.frame = CGRect(x: x, y: 0, width: width, height: bounds.height)
            pair.fill.cornerRadius = radius
            pair.fill.opacity = part.value > 0 ? 1 : 0
            pair.stripes.frame = pair.fill.bounds
            if part.value > 0 { x += width + Self.gap }
        }
        if revealed || !reveals { reveal.frame = bounds }
    }

    /// The bar draws itself in from the left the first time it is in a window with a size.
    private func revealIfNeeded() {
        guard !revealed, window != nil, bounds.width > 0 else { return }
        revealed = true
        guard reveals, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            still { reveal.frame = bounds }
            return
        }
        still { reveal.frame = CGRect(x: 0, y: 0, width: 0, height: bounds.height) }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.6)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1))
        reveal.frame = bounds
        CATransaction.commit()
    }
}
