import AppKit
import SwiftUI

/// A live line that never stops moving: each new sample redraws the path once, then Core Animation slides it left by one
/// step over the sampling interval, so the newest point glides in from the right edge just as the next sample arrives.
/// - Important: The render server plays the slide, so it costs the app nothing per frame. The same scroll in SwiftUI
///   re-rendered the card on the CPU for every frame; stepping instead looked choppy.
struct LiveLine: NSViewRepresentable {
    enum Style {
        /// One P-QRS-T beat per value (0...1), `beats` visible.
        case heartbeat(beats: Int, baseline: CGFloat)
        /// A trend line with a soft fill, `slots` points visible, on a scale up to `ceiling` (or the largest value).
        case sparkline(slots: Int, ceiling: Double?)
    }

    /// Oldest first. One more value than fits is used to fill the gap on the left while sliding.
    let values: [Double]
    /// Changes once per sample; a change starts the next slide.
    let sampleID: Int
    let style: Style
    let tint: Color
    var lineWidth: CGFloat = 1.5
    /// Fades the oldest part on the left, like a monitor trace.
    var fadesLeadingEdge = false
    var interval: Double = 2

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> LiveLineView { LiveLineView() }

    func updateNSView(_ view: LiveLineView, context: Context) {
        view.update(LiveLineView.Configuration(values: values, sampleID: sampleID, style: style, tint: NSColor(tint), lineWidth: lineWidth,
                                               fadesLeadingEdge: fadesLeadingEdge, interval: interval, moving: !reduceMotion))
    }
}

final class LiveLineView: NSView {
    struct Configuration {
        let values: [Double]
        let sampleID: Int
        let style: LiveLine.Style
        let tint: NSColor
        let lineWidth: CGFloat
        let fadesLeadingEdge: Bool
        let interval: Double
        let moving: Bool
    }

    private let strip = CALayer()
    private let line = CAShapeLayer()
    private let fill = CAGradientLayer()
    private let fillShape = CAShapeLayer()
    private let fade = CAGradientLayer()
    private var configuration: Configuration?
    private var drawnSize = CGSize.zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        line.fillColor = nil
        line.lineCap = .round
        line.lineJoin = .round
        fill.mask = fillShape
        strip.addSublayer(fill)
        strip.addSublayer(line)
        layer?.addSublayer(strip)
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        fade.colors = [NSColor.clear.cgColor, NSColor.black.cgColor]
        fade.locations = [0, 0.3]
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    /// SwiftUI paths grow downward.
    override var isFlipped: Bool { true }

    func update(_ new: Configuration) {
        let advanced = configuration.map { $0.sampleID != new.sampleID } ?? false
        configuration = new
        redraw(sliding: advanced && new.moving)
    }

    override func layout() {
        super.layout()
        if bounds.size != drawnSize { redraw(sliding: false) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        redraw(sliding: false)
    }

    private func redraw(sliding: Bool) {
        guard let configuration, bounds.width > 0, bounds.height > 0 else { return }
        drawnSize = bounds.size
        let (path, area, step) = paths(for: configuration, in: bounds.size)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        strip.frame = bounds
        line.frame = bounds
        fill.frame = bounds
        fillShape.frame = bounds
        line.path = path
        line.lineWidth = configuration.lineWidth
        fillShape.path = area
        effectiveAppearance.performAsCurrentDrawingAppearance {
            line.strokeColor = configuration.tint.cgColor
            fill.colors = [configuration.tint.withAlphaComponent(0.22).cgColor, configuration.tint.withAlphaComponent(0).cgColor]
        }
        fill.isHidden = area == nil
        fade.frame = bounds
        layer?.mask = configuration.fadesLeadingEdge ? fade : nil
        CATransaction.commit()

        strip.removeAnimation(forKey: "slide")
        guard sliding else { return }
        let slide = CABasicAnimation(keyPath: "transform.translation.x")
        slide.fromValue = step
        slide.toValue = 0
        // A little longer than the interval, so a late sample never leaves the line standing still.
        slide.duration = configuration.interval * 1.08
        slide.timingFunction = CAMediaTimingFunction(name: .linear)
        strip.add(slide, forKey: "slide")
    }

    /// The line (and the fill area for sparklines) with the newest value at the right edge and one extra step drawn past
    /// the left edge, plus the step width the slide covers.
    private func paths(for configuration: Configuration, in size: CGSize) -> (CGPath, CGPath?, CGFloat) {
        switch configuration.style {
        case .heartbeat(let beats, let baseline):
            let slot = size.width / CGFloat(max(beats, 1))
            let wide = PulseLine.path(loads: configuration.values, beats: beats + 1, in: CGSize(width: size.width + slot, height: size.height),
                                      baseline: baseline)
            return (wide.applying(CGAffineTransform(translationX: -slot, y: 0)).cgPath, nil, slot)
        case .sparkline(let slots, let ceiling):
            let values = configuration.values.suffix(slots + 1)
            let step = size.width / CGFloat(max(slots - 1, 1))
            guard values.count > 1 else { return (CGMutablePath(), nil, step) }
            let top = max(ceiling ?? values.max() ?? 1, 0.000_1)
            let points = values.enumerated().map { index, value in
                CGPoint(x: size.width - CGFloat(values.count - 1 - index) * step,
                        y: size.height - 1 - CGFloat(min(max(value / top, 0), 1)) * (size.height - 2))
            }
            let line = CGMutablePath()
            line.addLines(between: points)
            let area = line.mutableCopy() ?? CGMutablePath()
            area.addLine(to: CGPoint(x: points[points.count - 1].x, y: size.height))
            area.addLine(to: CGPoint(x: points[0].x, y: size.height))
            area.closeSubpath()
            return (line, area, step)
        }
    }
}
