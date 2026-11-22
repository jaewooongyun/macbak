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
    }

    private func memoryTile(_ memory: MemoryUsage) -> some View {
        Tile(help: "메모리 화면 열기", action: { open(.memory, $0) }) {
            CardHeader("메모리", symbol: "memorychip") { OpenHint() }
            HStack(spacing: 16) {
                RingGauge(fraction: memory.usedFraction, tint: memory.pressure?.tint ?? .blue, lineWidth: 10) {
                    RingCenter(value: (memory.usedFraction * 100).percentText, caption: "사용")
                }
                .frame(width: 92, height: 92)
                VStack(alignment: .leading, spacing: 4) {
                    RollingText(text: memory.used.memoryText, value: Double(memory.used), size: 22)
                    Text("/ \(memory.physical.memoryText)").font(.callout).foregroundStyle(.secondary)
                    if let pressure = memory.pressure { StatusTag(pressure).font(.callout) }
                }
            }
            Sparkline(values: system.history.map { Double($0.used) }, sampleID: system.history.last?.id ?? 0, ceiling: Double(memory.physical),
                      capacity: SystemMonitor.historyCapacity, tint: memory.pressure?.tint ?? .blue)
                .frame(height: 30)
        }
    }

    private func diskTile(_ disk: DiskUsage) -> some View {
        Tile(help: "디스크 화면 열기", action: { open(.disk, $0) }) {
            CardHeader(disk.name, symbol: "internaldrive") { OpenHint() }
            HStack(spacing: 16) {
                RingGauge(fraction: disk.usedFraction, tint: .blue, lineWidth: 10) {
                    RingCenter(value: (disk.usedFraction * 100).percentText, caption: "사용")
                }
                .frame(width: 92, height: 92)
                VStack(alignment: .leading, spacing: 4) {
                    RollingText(text: disk.available.diskText, value: Double(disk.available), size: 22)
                    Text("남음 · 전체 \(disk.total.diskText)").font(.callout).foregroundStyle(.secondary)
                }
            }
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
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(ready.diskText).font(Theme.numeral(30)).monospacedDigit()
                    Text(CleanupStatus.ready.title).font(.callout).foregroundStyle(.secondary)
                }
                LegendRow(CleanupStatus.review.tint, title: "직접 골라야 하는 데이터", value: review.diskText)
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
                Text("꺼짐").font(Theme.numeral(30))
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

/// The Mac's pulse: a heart rate from the busiest of CPU, GPU and memory, the load history as a heart monitor,
/// a runner keeping pace, and the three meters behind it.
struct PulseHero: View {
    @Environment(SystemMonitor.self) private var system
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var width: CGFloat = 0

    var body: some View {
        let reading = system.vitals.isEmpty ? nil : PulseReading(loads: system.vitals.map(\.load))
        let wide = width == 0 || width >= 620
        let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 32)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 18))
        Card {
            layout {
                VStack(alignment: .leading, spacing: 4) {
                    Label {
                        Text("맥박").font(.headline)
                    } icon: {
                        Beat(style: .heart, trigger: system.vitals.last?.id ?? 0).frame(width: 16, height: 16)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        // The column has a fixed width, so rolling digits never push the trace beside them.
                        RollingText(text: reading.map { "\($0.bpm)" } ?? "–", value: Double(reading?.bpm ?? 0), size: 60)
                        Text("BPM").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    Text(reading?.mood.title ?? "재는 중").font(.title2.weight(.semibold))
                    PaceRunner(mood: reading?.mood ?? .calm)
                        .frame(height: 38)
                        .padding(.top, 6)
                }
                // Fixed width: digits changing must not move the trace beside it, which would redraw its canvas every frame.
                .frame(width: wide ? 210 : nil, alignment: .leading)
                .help(PulseReading.explanation)

                VStack(alignment: .leading, spacing: 14) {
                    HeartbeatTrace(samples: system.vitals, height: wide ? 96 : 72)
                    VitalMeters(sample: system.vitals.last, pressure: system.memory?.pressure)
                    Text("CPU·GPU·메모리 중 가장 바쁜 자원의 평균 · 2초마다").font(.callout).foregroundStyle(.tertiary)
                }
            }
        }
        // The beat column and the trace flow between side by side and stacked as the window crosses 620pt.
        .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.15), value: wide)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}
