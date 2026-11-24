import AppKit
import SwiftUI

/// The activity rings and beating heart of the glance pulse card and the menu bar panel, in Core Animation.
/// - Important: The app sets each new value once per 2-second sample; the render server plays every endless motion (the
///   flow, the cap's pulse, the heart). A SwiftUI animation here would be a main-thread commit on every frame, the cost
///   `Theme.liveChange` documents. The motions stop while the window is covered, minimized or closed, and with Reduce
///   Motion.

private extension CALayer {
    /// Changes how fast this layer's animations run without moving them: the layer's current local time is kept, so a
    /// rotation or a beat carries on from where it is instead of jumping.
    /// - Important: It retimes the layer and everything under it, so it suits a leaf layer that holds one repeat.
    /// - Note: Checked in a test app: 34 rate changes over 9 s, none moved the layer's local time.
    func setRate(_ rate: Float) {
        guard speed != rate else { return }
        let now = CACurrentMediaTime()
        let local = convertTime(now, from: nil)
        timeOffset = local
        beginTime = now
        speed = rate
    }
}

/// The endless motions (flow, cap pulse, heart) step at most 30 times a second. While anything in a window animates,
/// WindowServer composites that display on every frame: a single beating heart cost 18 to 25 points of a core on the
/// 120 Hz built-in display, and this cap halved the rings' cost (measured November 2026).
private var endlessFrameRate: CAFrameRateRange { CAFrameRateRange(minimum: 10, maximum: 30, preferred: 30) }

/// Where a value sits on a ring that fills clockwise from the top, as a rotation of a layer whose mark starts at the top.
/// Unflipped layer coordinates turn counterclockwise for positive angles, so clockwise is negative.
private func ringAngle(_ value: Double) -> Double { -2 * .pi * value }

/// Whether a window shows any part of itself; nil (no window) counts as hidden. An ordered-out window (the closed menu bar
/// panel) counts as hidden even before its occlusion state catches up.
@MainActor private func onScreen(_ window: NSWindow?) -> Bool {
    guard let window else { return false }
    return window.isVisible && window.occlusionState.contains(.visible)
}

// MARK: - Activity ring

/// A value as a ring that fills clockwise from the top, a shade darker at its start. A light band flows along the fill at
/// a speed that follows the value, the end of the fill pulses at `bpm`, and a short tick marks the recent peak.
struct ActivityRing: NSViewRepresentable {
    let value: Double?
    let peak: Double?
    let tint: Color
    let bpm: Int?
    var lineWidth: CGFloat = 12
    /// How far the peak tick reaches past each edge of the ring; rings nested close together use less so neighbours keep apart.
    var tickOverhang: CGFloat = 2
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> ActivityRingView { ActivityRingView() }

    func updateNSView(_ view: ActivityRingView, context: Context) {
        view.set(value: value, peak: peak, tint: NSColor(tint), bpm: bpm, lineWidth: lineWidth, tickOverhang: tickOverhang,
                 reduceMotion: reduceMotion)
    }
}

final class ActivityRingView: LiveShapeView {
    private let track = CAShapeLayer()
    private let fill = CAGradientLayer()
    private let fillMask = CAShapeLayer()
    private let flowHost = CALayer()
    private let flowMask = CAShapeLayer()
    private let flow = CAGradientLayer()
    private let peakHost = CALayer()
    private let peakTick = CAShapeLayer()
    private let capHost = CALayer()
    private let cap = CALayer()

    private var value: Double?
    private var peak: Double?
    private var tint = NSColor.systemPink
    private var bpm: Int?
    private var lineWidth: CGFloat = 12
    private var tickOverhang: CGFloat = 2
    private var reduceMotion = false
    /// The angles last given to the cap and the peak tick: each turn animates from here.
    private var capAngle = 0.0
    private var peakAngle = 0.0
    private var occlusion: NSObjectProtocol?
    /// Whether the motions may run in this window. Tests swap it to drive the shown and hidden paths through the real
    /// occlusion observer, which a test process cannot do with a real window.
    var visibility: @MainActor (NSWindow?) -> Bool = onScreen

    override init(frame: NSRect) {
        super.init(frame: frame)
        for shape in [track, fillMask, flowMask] {
            shape.fillColor = nil
            shape.lineCap = .round
            shape.strokeColor = NSColor.black.cgColor
        }
        fill.type = .conic
        flow.type = .conic
        fill.mask = fillMask
        flowHost.mask = flowMask
        flowHost.addSublayer(flow)
        peakTick.lineCap = .round
        peakTick.lineWidth = 2
        peakHost.addSublayer(peakTick)
        capHost.addSublayer(cap)
        for sub in [track, fill, flowHost, peakHost, capHost] { layer?.addSublayer(sub) }
        fillMask.strokeEnd = 0
        flowMask.strokeEnd = 0
    }

    required init?(coder: NSCoder) { nil }

    func set(value: Double?, peak: Double?, tint: NSColor, bpm: Int?, lineWidth: CGFloat, tickOverhang: CGFloat = 2, reduceMotion: Bool) {
        let old = self.value
        self.value = value.map { min(max($0, 0), 1) }
        self.peak = peak.map { min(max($0, 0), 1) }
        self.tint = tint
        self.bpm = bpm
        self.reduceMotion = reduceMotion
        if lineWidth != self.lineWidth || tickOverhang != self.tickOverhang {
            self.lineWidth = lineWidth
            self.tickOverhang = tickOverhang
            needsLayout = true
        }
        paint()
        // Model values are set straight away (no reveal from empty), so the first fill shows whichever of layout,
        // joining a window and this call comes first.
        let shown = self.value ?? 0
        let animated = !reduceMotion && old != nil
        glide(animated: animated) {
            self.fillMask.strokeEnd = shown
            self.flowMask.strokeEnd = shown
        }
        turn(capHost, from: &capAngle, to: ringAngle(shown), animated: animated)
        turn(peakHost, from: &peakAngle, to: ringAngle(self.peak ?? 0), animated: animated)
        still {
            let live = self.value != nil
            capHost.isHidden = !live
            peakHost.isHidden = !live || self.peak == nil || abs((self.peak ?? 0) - shown) < 0.01
        }
        updateMotion()
    }

    /// Turns a layer to an angle along the ring over the same 0.22 s as the fill, so the cap stays on the end of the arc.
    private func turn(_ host: CALayer, from current: inout Double, to angle: Double, animated: Bool) {
        guard angle != current else { return }
        if animated && window != nil {
            let move = CABasicAnimation(keyPath: "transform.rotation.z")
            move.fromValue = current
            move.toValue = angle
            move.duration = 0.22
            move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            host.add(move, forKey: "turn")
        }
        still { host.setValue(angle, forKeyPath: "transform.rotation.z") }
        current = angle
    }

    override func paint() {
        resolve {
            track.strokeColor = NSColor.quaternaryLabelColor.cgColor
            // A conic gradient runs counterclockwise from the top and the arc clockwise, so the colours go light to dark
            // along the gradient; the sliver just counterclockwise of the top (under the start's round cap) stays dark.
            let dark = tint.blended(withFraction: 0.3, of: .black) ?? tint
            fill.colors = [dark.cgColor, dark.cgColor, tint.cgColor, dark.cgColor]
            fill.locations = [0, 0.025, 0.035, 1]
            let clear = NSColor.white.withAlphaComponent(0).cgColor
            let shine = NSColor.white.withAlphaComponent(0.35).cgColor
            flow.colors = [clear, shine, clear, clear]
            flow.locations = [0, 0.12, 0.25, 1]
            peakTick.strokeColor = NSColor.secondaryLabelColor.cgColor
            cap.backgroundColor = NSColor.white.withAlphaComponent(0.9).cgColor
        }
    }

    override func layout() {
        super.layout()
        let side = min(bounds.width, bounds.height) - lineWidth
        guard side > 0 else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = side / 2
        let path = CGMutablePath()
        // Unflipped view: angles grow counterclockwise, so start at the top and go clockwise.
        path.addArc(center: center, radius: radius, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        let tick = CGMutablePath()
        tick.move(to: CGPoint(x: center.x, y: center.y + radius - (lineWidth / 2 + tickOverhang)))
        tick.addLine(to: CGPoint(x: center.x, y: center.y + radius + lineWidth / 2 + tickOverhang))
        let capSide = lineWidth * 0.9
        still {
            for shape in [track, fillMask, flowMask] {
                shape.frame = bounds
                shape.path = path
                shape.lineWidth = lineWidth
            }
            // Hosts turn about the ring's centre.
            for host in [fill, flowHost, flow, peakHost, capHost] as [CALayer] {
                host.bounds = CGRect(origin: .zero, size: bounds.size)
                host.position = center
            }
            fill.startPoint = CGPoint(x: 0.5, y: 0.5)
            fill.endPoint = CGPoint(x: 0.5, y: 1)
            flow.startPoint = CGPoint(x: 0.5, y: 0.5)
            flow.endPoint = CGPoint(x: 0.5, y: 1)
            peakTick.frame = CGRect(origin: .zero, size: bounds.size)
            peakTick.path = tick
            cap.bounds = CGRect(x: 0, y: 0, width: capSide, height: capSide)
            cap.cornerRadius = capSide / 2
            cap.position = CGPoint(x: center.x, y: center.y + radius)
        }
    }

    /// Leaving a window removes the repeats; joining one adds them once (adding under the same key replaces).
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        occlusion.map(NotificationCenter.default.removeObserver)
        occlusion = nil
        if let window {
            occlusion = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                               object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateMotion() }
            }
        }
        updateMotion()
    }

    /// Runs the flow and the cap's pulse only while they can be seen. Removing them explicitly matters: turning off a
    /// SwiftUI transaction does not stop a Core Animation repeat.
    private func updateMotion() {
        let moving = visibility(window) && !reduceMotion && value != nil
        // Held still, the light band would sit on the ring as a fixed bright patch, so it shows only while it flows
        // (below 1% its speed is 0).
        still { flowHost.isHidden = !moving || (value ?? 0) < 0.01 }
        guard moving, let value else {
            flow.removeAnimation(forKey: "flow")
            cap.removeAnimation(forKey: "beat")
            return
        }
        if flow.animation(forKey: "flow") == nil {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi  // clockwise
            spin.duration = 2               // one turn every 2 s at 100%
            spin.repeatCount = .infinity
            spin.isRemovedOnCompletion = false
            spin.preferredFrameRateRange = endlessFrameRate
            flow.add(spin, forKey: "flow")
        }
        if cap.animation(forKey: "beat") == nil {
            let beat = CAKeyframeAnimation(keyPath: "transform.scale")
            beat.values = [1, 1.35, 1, 1]
            beat.keyTimes = [0, 0.15, 0.45, 1]
            beat.duration = 1  // one beat a second at speed 1, so speed = BPM / 60
            beat.repeatCount = .infinity
            beat.isRemovedOnCompletion = false
            beat.preferredFrameRateRange = endlessFrameRate
            cap.add(beat, forKey: "beat")
        }
        flow.setRate(value < 0.01 ? 0 : Float(value))
        cap.setRate(Float(bpm ?? 60) / 60)
    }
}

// MARK: - Heart

/// A heart that beats at `bpm`; still without a reading or with Reduce Motion.
struct BeatingHeart: NSViewRepresentable {
    let bpm: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> BeatingHeartView { BeatingHeartView() }

    func updateNSView(_ view: BeatingHeartView, context: Context) {
        view.set(bpm: bpm, reduceMotion: reduceMotion)
    }
}

final class BeatingHeartView: LiveShapeView {
    private let mark = CALayer()
    private var bpm: Int?
    private var reduceMotion = false
    private var occlusion: NSObjectProtocol?
    /// Whether the beat may run in this window; see `ActivityRingView.visibility`.
    var visibility: @MainActor (NSWindow?) -> Bool = onScreen

    override init(frame: NSRect) {
        super.init(frame: frame)
        mark.contentsGravity = .resizeAspect
        layer?.addSublayer(mark)
    }

    required init?(coder: NSCoder) { nil }

    func set(bpm: Int?, reduceMotion: Bool) {
        self.bpm = bpm
        self.reduceMotion = reduceMotion
        updateMotion()
    }

    override func paint() {
        resolve {
            let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.systemPink]))
            mark.contents = NSImage(systemSymbolName: "heart.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config)
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        mark.contentsScale = window?.backingScaleFactor ?? 2
    }

    override func layout() {
        super.layout()
        still {
            mark.bounds = CGRect(origin: .zero, size: bounds.size)
            mark.position = CGPoint(x: bounds.midX, y: bounds.midY)
        }
    }

    /// Same window handling as the ring: repeats come off when the view leaves its window or the window is hidden.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        mark.contentsScale = window?.backingScaleFactor ?? 2
        paint()
        occlusion.map(NotificationCenter.default.removeObserver)
        occlusion = nil
        if let window {
            occlusion = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                               object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateMotion() }
            }
        }
        updateMotion()
    }

    private func updateMotion() {
        guard visibility(window), !reduceMotion, let bpm else {
            mark.removeAnimation(forKey: "beat")
            return
        }
        if mark.animation(forKey: "beat") == nil {
            // A quick swell and a small rebound, held still for the rest of each beat.
            let beat = CAKeyframeAnimation(keyPath: "transform.scale")
            beat.values = [1, 1.28, 0.94, 1, 1]
            beat.keyTimes = [0, 0.13, 0.29, 0.45, 1]
            beat.duration = 1
            beat.repeatCount = .infinity
            beat.isRemovedOnCompletion = false
            beat.preferredFrameRateRange = endlessFrameRate
            mark.add(beat, forKey: "beat")
        }
        mark.setRate(Float(bpm) / 60)
    }
}
