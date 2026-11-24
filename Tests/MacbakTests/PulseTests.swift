import AppKit
import Testing
@testable import Macbak

@Test func oneSpikeNeitherJumpsTheRateNorFlipsTheMood() {
    let calm = Array(repeating: 0.1, count: 20)
    let spiked = PulseReading(loads: calm + [0.95])
    #expect(spiked.mood == .calm)
    #expect(spiked.bpm <= PulseReading(loads: calm).bpm + 11)
}

@Test func sustainedLoadChangesMoodWithAGapBeforeReturning() {
    let busy = PulseReading(loads: Array(repeating: 0.4, count: 20))
    #expect(busy.mood == .busy)
    // 0.25 is below the enter threshold but above the leave threshold: still busy.
    #expect(PulseReading(loads: Array(repeating: 0.4, count: 20) + Array(repeating: 0.25, count: 20)).mood == .busy)
    #expect(PulseReading(loads: Array(repeating: 0.4, count: 20) + Array(repeating: 0.1, count: 20)).mood == .calm)
    #expect(PulseReading(loads: Array(repeating: 0.9, count: 20)).mood == .racing)
}

@Test func theBusiestResourceSetsThePace() {
    let gpuBound = VitalSample(id: 0, cpu: 0.2, gpu: 0.7, memory: 0.45, memoryLevel: .normal)
    #expect(gpuBound.load == 0.7 && gpuBound.leader == .gpu)
    // Under normal pressure memory counts half: 45% shown, 22.5% toward the pulse, so a 30% CPU leads.
    let healthy = VitalSample(id: 1, cpu: 0.3, gpu: nil, memory: 0.45, memoryLevel: .normal)
    #expect(healthy.value(of: .memory) == 0.45 && healthy.leader == .cpu && healthy.load == 0.3)
    // Once macOS warns, memory counts in full with a floor, and it races the heart when critical.
    let squeezed = VitalSample(id: 2, cpu: 0.1, gpu: nil, memory: 0.7, memoryLevel: .critical)
    #expect(squeezed.leader == .memory && PulseReading(loads: Array(repeating: squeezed.load, count: 10)).mood == .racing)
    #expect(VitalSample(id: 3, cpu: 0.3, gpu: nil, memory: nil).load == 0.3)
}

@MainActor @Test func aSegmentThatLeavesTheBarTakesItsLayerWithIt() throws {
    let bar = SegmentBarView(reveals: false)
    let parts = ["apps", "cache", "free"].map { SegmentBarView.Part(id: $0, value: 1, color: .systemBlue, striped: false) }
    bar.set(parts, animated: false)
    let three = try #require(bar.layer?.sublayers?.count)
    bar.set(Array(parts.prefix(2)), animated: false)
    #expect(bar.layer?.sublayers?.count == three - 1)
}

@MainActor @Test func aSegmentReplacedAtTheSameShareIsStillPlaced() {
    let bar = SegmentBarView(reveals: false)
    bar.frame = NSRect(x: 0, y: 0, width: 100, height: 10)
    func part(_ id: String) -> SegmentBarView.Part { .init(id: id, value: 1, color: .systemBlue, striped: false) }
    bar.set([part("a"), part("b")], animated: false)
    bar.set([part("c"), part("b")], animated: false)
    #expect(bar.layer?.sublayers?.allSatisfy { $0.frame.width > 0 } == true)
}

// MARK: - Peak window and the panel's nested rings

@Test func thePeakForgetsEverythingAfterAGapLongerThanTenSeconds() {
    let start = Date(timeIntervalSinceReferenceDate: 0)
    let spike = VitalSample(id: 0, cpu: 0.9, gpu: nil, memory: nil)
    let newest = VitalSample(id: 1, cpu: 0.2, gpu: nil, memory: nil)
    var window = PeakWindow()
    #expect(window.peak(of: .cpu, in: [], at: start) == nil)
    #expect(window.peak(of: .cpu, in: [spike], at: start) == 0.9)  // the newest counts before it is stamped
    window.stamp(spike.id, at: start)
    #expect(window.peak(of: .cpu, in: [spike, newest], at: start.addingTimeInterval(10)) == 0.9)
    // A sleep or a stall: the old spike's age no longer says how recent it is, so only the newest counts.
    #expect(window.peak(of: .cpu, in: [spike, newest], at: start.addingTimeInterval(10.1)) == 0.2)
}

@Test func thePeakCountsTheLastMinuteOnly() {
    let start = Date(timeIntervalSinceReferenceDate: 0)
    var vitals = [VitalSample(id: 0, cpu: 0.9, gpu: nil, memory: nil)]
    var window = PeakWindow()
    window.stamp(0, at: start)
    for id in 1...30 {  // a sample every 2 s, so no gap clears the window
        vitals.append(VitalSample(id: id, cpu: 0.2, gpu: nil, memory: nil))
        window.stamp(id, at: start.addingTimeInterval(Double(id) * 2))
    }
    #expect(window.peak(of: .cpu, in: vitals, at: start.addingTimeInterval(60)) == 0.9)
    #expect(window.peak(of: .cpu, in: vitals, at: start.addingTimeInterval(60.1)) == 0.2)
    #expect(window.peak(of: .gpu, in: vitals, at: start.addingTimeInterval(60)) == nil)
}

@Test func nestedRingsLeaveRoomBetweenTheirPeakTicks() {
    // A 6pt line and a 5pt gap: the rings' 1pt ticks stay 3pt apart, and the inner hole holds the 12pt heart.
    #expect(ConcentricVitalRings.diameters(for: 76) == [76, 54, 32])
}

/// The endless motions running in a layer tree (the ring's flow and cap pulse, the heart's beat), by key. A value's
/// short turn into place is not one.
@MainActor private func endlessMotions(_ layer: CALayer?) -> [String] {
    guard let layer else { return [] }
    let own = (layer.animationKeys() ?? []).filter { layer.animation(forKey: $0)?.repeatCount == .infinity }
    return own + (layer.sublayers ?? []).flatMap { endlessMotions($0) }
}

@MainActor private final class Shown {
    var value = false
}

/// A window that is never put on screen, like the menu bar panel at launch.
@MainActor private func hiddenWindow() -> NSWindow {
    NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless], backing: .buffered, defer: true)
}

@MainActor @Test func ringMotionsRunOnlyWhileTheirWindowShows() {
    let window = hiddenWindow()
    let ring = ActivityRingView(frame: NSRect(x: 0, y: 0, width: 76, height: 76))
    window.contentView?.addSubview(ring)
    ring.set(value: 0.5, peak: 0.7, tint: .systemPink, bpm: 80, lineWidth: 6, reduceMotion: false)
    #expect(endlessMotions(ring.layer).isEmpty)

    // The real occlusion observer reruns the check; the test only decides what the check answers.
    let shown = Shown()
    ring.visibility = { _ in shown.value }
    let occlusionChanged = { NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window) }
    shown.value = true
    occlusionChanged()
    #expect(Set(endlessMotions(ring.layer)) == ["flow", "beat"])
    shown.value = false
    occlusionChanged()
    #expect(endlessMotions(ring.layer).isEmpty)
    ring.set(value: 0.8, peak: 0.8, tint: .systemPink, bpm: 90, lineWidth: 6, reduceMotion: false)  // a sample while hidden
    #expect(endlessMotions(ring.layer).isEmpty)
    shown.value = true
    occlusionChanged()
    #expect(Set(endlessMotions(ring.layer)) == ["flow", "beat"])
    ring.set(value: 0.8, peak: 0.8, tint: .systemPink, bpm: 90, lineWidth: 6, reduceMotion: true)
    #expect(endlessMotions(ring.layer).isEmpty)
}

@MainActor @Test func theHeartBeatsOnlyWhileItsWindowShows() {
    let window = hiddenWindow()
    let heart = BeatingHeartView(frame: NSRect(x: 0, y: 0, width: 12, height: 12))
    window.contentView?.addSubview(heart)
    heart.set(bpm: 80, reduceMotion: false)
    #expect(endlessMotions(heart.layer).isEmpty)

    let shown = Shown()
    heart.visibility = { _ in shown.value }
    let occlusionChanged = { NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window) }
    shown.value = true
    occlusionChanged()
    #expect(endlessMotions(heart.layer) == ["beat"])
    shown.value = false
    occlusionChanged()
    #expect(endlessMotions(heart.layer).isEmpty)
    heart.set(bpm: 100, reduceMotion: false)  // a sample while hidden
    #expect(endlessMotions(heart.layer).isEmpty)
    shown.value = true
    occlusionChanged()
    #expect(endlessMotions(heart.layer) == ["beat"])
    heart.set(bpm: 100, reduceMotion: true)
    #expect(endlessMotions(heart.layer).isEmpty)
}
