import SwiftUI

/// The first screen: the Mac's pulse, then one tile per area. Every tile opens its own screen.
struct GlanceScreen: View {
    @Environment(SystemMonitor.self) private var system
    @Environment(AIMonitor.self) private var ai
    @Environment(AIStorage.self) private var storage
    @Environment(LoopScheduler.self) private var loop
    /// Opens a screen, growing it out of the tapped tile's frame.
    let open: (Screen, CGRect) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.gutter) {
                PulseHero().riseIn(0)
                LiquidGrid(minimumColumnWidth: 240, maximumColumns: 3) {
                    if let memory = system.memory { memoryTile(memory).riseIn(1) }
                    if let disk = system.disk { diskTile(disk).riseIn(2) }
                    aiTile.riseIn(3)
                    storageTile.riseIn(4)
                    loopTile.riseIn(5)
                    appsTile.riseIn(6).gridSpan(.max)
                }
            }
            .readableColumn()
        }
        .modifier(SoftScrollEdges())
    }

    private func memoryTile(_ memory: MemoryUsage) -> some View {
        Tile(help: "메모리 화면 열기", action: { open(.memory, $0) }) {
            CardHeader("메모리", symbol: "memorychip") { OpenHint() }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                RollingText(text: memory.used.memoryText, value: Double(memory.used), size: 22)
                Text("/ \(memory.physical.memoryText)").font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if let pressure = memory.pressure { StatusTag(pressure).font(.callout) }
            }
            MeterBar(fraction: memory.usedFraction, tint: memory.pressure?.tint ?? .blue)
            Text("사용 \((memory.usedFraction * 100).percentText)").font(.callout).foregroundStyle(.secondary)
            Sparkline(values: system.history.map { Double($0.used) }, sampleID: system.history.last?.id ?? 0, ceiling: Double(memory.physical),
                      capacity: SystemMonitor.historyCapacity, tint: memory.pressure?.tint ?? .blue)
                .frame(height: 30)
        }
    }

    private func diskTile(_ disk: DiskUsage) -> some View {
        Tile(help: "디스크 화면 열기", action: { open(.disk, $0) }) {
            CardHeader(disk.name, symbol: "internaldrive") { OpenHint() }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                RollingText(text: disk.available.diskText, value: Double(disk.available), size: 22)
                Text("남음 · 전체 \(disk.total.diskText)").font(.callout).foregroundStyle(.secondary)
            }
            MeterBar(fraction: disk.usedFraction, tint: .blue)
            Text("사용 \((disk.usedFraction * 100).percentText)").font(.callout).foregroundStyle(.secondary)
            if disk.purgeable > 0 {
                Text("남은 공간 중 \(disk.purgeable.diskText)는 macOS가 필요할 때 비웁니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var aiTile: some View {
        Tile(help: "AI 활동 화면 열기", action: { open(.aiActivity, $0) }) {
            CardHeader("AI", symbol: Screen.aiActivity.symbol) { OpenHint() }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                RollingText(text: "\(ai.totalSessions)", value: Double(ai.totalSessions), size: 34)
                Text("세션 · 도구 \(ai.tools.count)개 실행 중").font(.callout).foregroundStyle(.secondary)
            }
            if ai.tools.isEmpty {
                Text(ai.processSampledAt == nil ? "프로세스를 읽는 중입니다." : "실행 중인 AI 도구가 없습니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                SegmentBar(segments: AIVendor.allCases.map { vendor in
                    BarSegment(vendor.rawValue, Double(ai.tools.filter { $0.tool.vendor == vendor }.reduce(0) { $0 + $1.memory }), vendor.tint)
                }, height: 8)
                VStack(spacing: 6) {
                    ForEach(ai.tools.prefix(3)) { usage in
                        HStack(spacing: 8) {
                            Circle().fill(usage.tool.vendor.tint).frame(width: 8, height: 8)
                            Text(usage.tool.name).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(usage.memory.memoryText).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }
            }
        }
    }

    private var storageTile: some View {
        Tile(help: "AI 저장 공간 화면 열기", action: { open(.aiStorage, $0) }) {
            CardHeader("정리할 수 있는 공간", symbol: Screen.aiStorage.symbol) { OpenHint() }
            if let report = storage.report {
                let ready = report.candidates.filter { $0.verdict.status == .ready }.reduce(0) { $0 + $1.bytes }
                let review = report.candidates.filter { $0.verdict.status == .review }.reduce(0) { $0 + $1.bytes }
                if ready > 0 {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(ready.diskText).font(Theme.numeral(30)).monospacedDigit()
                        Text(CleanupStatus.ready.title).font(.callout).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        StatusTag(title: "직접 골라야 하는 데이터", symbol: CleanupStatus.review.symbol, tint: CleanupStatus.review.tint)
                        Spacer(minLength: 8)
                        Text(review.diskText).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.callout)
                } else {
                    // Nothing passed every check, so what waits for a choice is the number worth reading.
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(review.diskText).font(Theme.numeral(30)).monospacedDigit()
                        Text("직접 골라야 하는 데이터").font(.callout).foregroundStyle(.secondary)
                    }
                }
                Text("AI 도구 폴더 · \(report.scannedAt.formatted(.relative(presentation: .named))) 검사").font(.callout).foregroundStyle(.secondary)
            } else {
                Text(storage.scanning ? "검사하는 중…" : "아직 검사하지 않았습니다").font(.title3.weight(.semibold))
                Text("열면 AI 도구 폴더의 크기와 판정을 확인합니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var loopTile: some View {
        Tile(help: "루프 화면 열기", action: { open(.loop, $0) }) {
            CardHeader("정기 정리", symbol: Screen.loop.symbol) { OpenHint() }
            if let next = loop.nextRun {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(next.formatted(.dateTime.hour().minute())).font(Theme.numeral(30)).monospacedDigit()
                    Text(next.formatted(.dateTime.weekday(.wide))).font(.callout).foregroundStyle(.secondary)
                }
                Text("다음 정리 \(next.formatted(.relative(presentation: .named)))").font(.callout).foregroundStyle(.secondary)
            } else {
                Text("꺼짐").font(.title3.weight(.semibold))
                Text("정기 정리가 꺼져 있습니다").font(.callout).foregroundStyle(.secondary)
            }
            if let last = loop.lastRun {
                Text("마지막 실행 \(last.date.formatted(.relative(presentation: .named))) · \(last.readySummary)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var appsTile: some View {
        Tile(help: "메모리 화면 열기", action: { open(.memory, $0) }) {
            CardHeader("메모리를 많이 쓰는 앱", symbol: "square.stack.3d.up") {
                Text("앱 본체 프로세스 기준").font(.callout).foregroundStyle(.secondary)
                OpenHint()
            }
            AppUsageList(apps: Array(system.apps.prefix(4)))
        }
    }
}

/// On macOS 26 and later, cards scrolling under the toolbar or past the bottom fade softly instead of being cut.
private struct SoftScrollEdges: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        } else {
            content
        }
    }
}

/// The Mac's pulse: a heart beating at the rate set by the busiest of CPU, GPU and memory, and the three as activity
/// rings, each with its peak over the last minute.
struct PulseHero: View {
    @Environment(SystemMonitor.self) private var system
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var width: CGFloat = 0
    /// When this card saw each sample, by sample id. Samples carry no time, so the card stamps them as they arrive; only
    /// samples it saw in the last minute count toward a ring's peak.
    @State private var seen: [Int: Date] = [:]

    var body: some View {
        let reading = system.vitals.isEmpty ? nil : PulseReading(loads: system.vitals.map(\.load))
        let sample = system.vitals.last
        let wide = width == 0 || width >= 620
        let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 32)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 18))
        Card {
            layout {
                VStack(alignment: .leading, spacing: 4) {
                    Label {
                        Text("맥박").font(.headline)
                    } icon: {
                        BeatingHeart(bpm: reading?.bpm).frame(width: 16, height: 16)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        // The column has a fixed width, so rolling digits never push the rings beside them.
                        RollingText(text: reading.map { "\($0.bpm)" } ?? "–", value: Double(reading?.bpm ?? 0), size: 60)
                        Text("BPM").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    Text(reading?.mood.title ?? "재는 중").font(.title2.weight(.semibold))
                }
                .frame(width: wide ? 210 : nil, alignment: .leading)
                .help(PulseReading.explanation)

                VStack(alignment: .leading, spacing: 14) {
                    AdaptiveGrid(minimumColumnWidth: 96, maximumColumns: 3, spacing: 16) {
                        ForEach(VitalSample.Vital.allCases, id: \.self) { vital in
                            ring(vital, sample: sample, bpm: reading?.bpm)
                        }
                    }
                    Text("CPU·GPU·메모리 중 가장 바쁜 자원의 평균 · 2초마다").font(.callout).foregroundStyle(.tertiary)
                }
            }
        }
        // The heart column and the rings flow between side by side and stacked as the window crosses 620pt.
        .animation(reduceMotion ? nil : Theme.morph, value: wide)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        // Samples held from before the card appeared are not dated: a sleep or a throttled timer can lie between them,
        // and an old spike would pass for a recent peak. Only the newest is stamped, so the peak builds up from here.
        .onAppear { stampNewest() }
        .onChange(of: system.vitals.last?.id) { stampNewest() }
    }

    private func ring(_ vital: VitalSample.Vital, sample: VitalSample?, bpm: Int?) -> some View {
        let value = sample?.value(of: vital)
        let pressure = system.memory?.pressure
        let tint: Color = switch vital {
        case .cpu: .pink
        case .gpu: .indigo
        case .memory: pressure?.tint ?? .green
        }
        return VStack(spacing: 8) {
            ActivityRing(value: value, peak: peak(of: vital), tint: tint, bpm: bpm)
                .frame(width: 96, height: 96)
            HStack(spacing: 4) {
                Text(vital.title).font(.callout.weight(.medium)).foregroundStyle(.secondary)
                if sample?.leader == vital, value != nil {
                    Image(systemName: "heart.fill").font(.caption).foregroundStyle(.pink)
                        .accessibilityLabel("맥박을 정하는 자원")
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value.map { ($0 * 100).percentText } ?? "–").font(Theme.numeral(18)).monospacedDigit()
                if vital == .memory, value != nil, let pressure {
                    Text(pressure.shortTitle).font(.callout).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(vital.title)
        .accessibilityValue(sample == nil ? "재는 중" : spokenValue(vital, value: value, pressure: pressure, leads: sample?.leader == vital))
        .help(vital == .memory ? "메모리 압력: 100 − macOS가 사용 가능하다고 보는 메모리 비율. 압력이 보통이면 맥박에는 절반만 반영합니다." : "")
    }

    /// What VoiceOver reads after the ring's name: the value, the memory pressure level, and whether this resource sets
    /// the pulse — everything the ring shows beside its number.
    private func spokenValue(_ vital: VitalSample.Vital, value: Double?, pressure: MemoryPressure?, leads: Bool) -> String {
        guard let value else { return "읽을 수 없음" }
        var parts = [(value * 100).percentText]
        if vital == .memory, let pressure { parts.append("압력 \(pressure.shortTitle)") }
        if leads { parts.append("맥박을 정하는 자원") }
        return parts.joined(separator: ", ")
    }

    /// The highest value among the samples seen in the last minute; nil before any. The newest counts before it is
    /// stamped and the old stamps stop counting before they are dropped (both happen after this render), so the peak is
    /// never below the value the ring shows nor older than a minute.
    private func peak(of vital: VitalSample.Vital) -> Double? {
        let live = Self.live(seen, at: .now)
        let newest = system.vitals.last?.id
        return system.vitals.filter { live[$0.id] != nil || $0.id == newest }.compactMap { $0.value(of: vital) }.max()
    }

    /// Stamps the newest sample and keeps only the stamps that still count.
    private func stampNewest() {
        guard let newest = system.vitals.last else { return }
        let now = Date.now
        seen = Self.live(seen, at: now)
        seen[newest.id] = now
    }

    /// The stamps that still count at `now`: those from the last minute, and none after a gap of more than 10 s (sleep,
    /// a stall), since their age no longer says how recent they are.
    private static func live(_ seen: [Int: Date], at now: Date) -> [Int: Date] {
        guard let latest = seen.values.max(), now.timeIntervalSince(latest) <= 10 else { return [:] }
        return seen.filter { now.timeIntervalSince($0.value) <= 60 }
    }
}
