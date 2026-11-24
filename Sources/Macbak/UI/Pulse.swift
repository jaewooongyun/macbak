import AppKit
import SwiftUI

/// The Mac's "pulse": how hard it is working, as a heart rate from 60 BPM (resting) to 120 BPM (one resource maxed out).
/// The load of a sample is its busiest resource — CPU, GPU or memory pressure — see `VitalSample.load`.
/// - Note: A metaphor for the glance. The rings and readouts beside it always show the real values and which one sets
///   the pace.
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
}

/// The highest value of each vital over the last minute, for the rings' peak ticks. Samples carry no time, so a view
/// stamps them as they arrive; only samples stamped in the last minute count.
struct PeakWindow {
    /// When each sample was seen, by sample id.
    private(set) var seen: [Int: Date] = [:]

    /// Stamps a sample and keeps only the stamps that still count.
    mutating func stamp(_ id: Int, at now: Date = .now) {
        seen = Self.live(seen, at: now)
        seen[id] = now
    }

    /// The highest value among the samples seen in the last minute; nil before any. The newest counts before it is
    /// stamped and the old stamps stop counting before they are dropped (both happen after a render), so the peak is
    /// never below the value the ring shows nor older than a minute.
    func peak(of vital: VitalSample.Vital, in vitals: [VitalSample], at now: Date = .now) -> Double? {
        let live = Self.live(seen, at: now)
        let newest = vitals.last?.id
        return vitals.filter { live[$0.id] != nil || $0.id == newest }.compactMap { $0.value(of: vital) }.max()
    }

    /// The stamps that still count at `now`: those from the last minute, and none after a gap of more than 10 s (sleep,
    /// a stall), since their age no longer says how recent they are.
    static func live(_ seen: [Int: Date], at now: Date) -> [Int: Date] {
        guard let latest = seen.values.max(), now.timeIntervalSince(latest) <= 10 else { return [:] }
        return seen.filter { now.timeIntervalSince($0.value) <= 60 }
    }
}

extension VitalSample.Vital {
    /// Each ring's colour: CPU pink, GPU indigo, memory in its pressure colour (green until macOS reports a level).
    func ringTint(pressure: MemoryPressure?) -> Color {
        switch self {
        case .cpu: .pink
        case .gpu: .indigo
        case .memory: pressure?.tint ?? .green
        }
    }

    /// What VoiceOver reads after the name: the value, the memory pressure level, and whether this resource sets the
    /// pulse — everything a ring or a readout shows beside its number.
    func spokenValue(_ value: Double?, pressure: MemoryPressure?, leads: Bool) -> String {
        guard let value else { return "읽을 수 없음" }
        var parts = [(value * 100).percentText]
        if self == .memory, let pressure { parts.append("압력 \(pressure.shortTitle)") }
        if leads { parts.append("맥박을 정하는 자원") }
        return parts.joined(separator: ", ")
    }
}

/// CPU, GPU and memory as three rings one inside the other with the beating heart in the middle: the menu bar panel's
/// pulse. Each ring carries its peak over the last minute, like the glance card's.
struct ConcentricVitalRings: View {
    let vitals: [VitalSample]
    let pressure: MemoryPressure?
    var size: CGFloat = 76

    nonisolated static let lineWidth: CGFloat = 6
    nonisolated static let gap: CGFloat = 5

    @State private var peaks = PeakWindow()

    /// Outer to inner. Each ring sits a line and a gap inside the last, so the 1pt peak ticks of neighbours keep apart.
    nonisolated static func diameters(for size: CGFloat) -> [CGFloat] {
        (0..<3).map { size - CGFloat($0) * 2 * (lineWidth + gap) }
    }

    var body: some View {
        let sample = vitals.last
        let bpm = vitals.isEmpty ? nil : PulseReading(loads: vitals.map(\.load)).bpm
        let diameters = Self.diameters(for: size)
        ZStack {
            ForEach(Array(VitalSample.Vital.allCases.enumerated()), id: \.element) { index, vital in
                ActivityRing(value: sample?.value(of: vital), peak: peaks.peak(of: vital, in: vitals),
                             tint: vital.ringTint(pressure: pressure), bpm: bpm, lineWidth: Self.lineWidth, tickOverhang: 1)
                    .frame(width: diameters[index], height: diameters[index])
            }
            BeatingHeart(bpm: bpm).frame(width: 12, height: 12)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)  // the readouts beside it say the same in words
        .help("바깥부터 CPU, GPU, 메모리입니다. 링을 가로지르는 짧은 눈금은 최근 1분 동안의 최고치입니다.")
        // As on the glance card, samples held from before the rings appeared are not dated; the peak builds up from here.
        .onAppear { stampNewest() }
        .onChange(of: vitals.last?.id) { stampNewest() }
    }

    private func stampNewest() {
        if let newest = vitals.last { peaks.stamp(newest.id) }
    }
}

/// CPU, GPU and memory as three fixed columns beside the panel's rings: name, value and, for memory, the pressure level.
/// The one setting the pace carries the heart.
/// - Note: Fixed columns, not `AdaptiveGrid`: beside the rings the panel leaves about 200pt, where the grid folds to two.
struct VitalReadouts: View {
    let sample: VitalSample?
    let pressure: MemoryPressure?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(VitalSample.Vital.allCases, id: \.self) { vital in
                readout(vital)
            }
        }
    }

    private func readout(_ vital: VitalSample.Vital) -> some View {
        let value = sample?.value(of: vital)
        let leads = sample?.leader == vital && value != nil
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                // "메모리 압력" and the heart do not fit a third of the panel; VoiceOver still reads the full name.
                Text(vital == .memory ? "메모리" : vital.title).font(.caption).foregroundStyle(.secondary)
                if leads {
                    Image(systemName: "heart.fill").font(.caption2).foregroundStyle(.pink)
                }
            }
            Text(value.map { ($0 * 100).percentText } ?? "–").font(Theme.numeral(15)).monospacedDigit()
            if vital == .memory, value != nil, let pressure {
                Text(pressure.shortTitle).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(vital.title)
        .accessibilityValue(sample == nil ? "재는 중" : vital.spokenValue(value, pressure: pressure, leads: leads))
        .help(vital == .memory ? "메모리 압력: 100 − macOS가 사용 가능하다고 보는 메모리 비율. 압력이 보통이면 맥박에는 절반만 반영합니다." : "")
    }
}
