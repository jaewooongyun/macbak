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
