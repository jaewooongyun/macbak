import Charts
import SwiftUI

struct MemoryScreen: View {
    @Environment(SystemMonitor.self) private var system
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Booted simulators; nil before the first read or when it failed.
    @State private var simulators: [BootedSimulator]?
    @State private var reading = false
    /// Simulators ticked to switch off, by UDID; the idle ones start ticked.
    @State private var picked: Set<String> = []
    /// Apps a person ticked to quit, as they were when ticked; nothing starts ticked.
    @State private var pickedApps = AppPicks()
    /// Orphaned tools a person ticked, as they were when ticked: a reused pid is a different process and is not offered.
    @State private var pickedOrphans: [pid_t: OrphanProcess] = [:]
    /// Idle sessions a person ticked, as they were when ticked: a session used since is a different one.
    @State private var pickedSessions: [pid_t: IdleSession] = [:]
    @State private var run: RunProgress?
    @State private var confirming = false

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.gutter) {
                if let memory = system.memory {
                    compositionCard(memory).riseIn(0)
                    LiquidGrid(minimumColumnWidth: 260, maximumColumns: 3) {
                        Card {
                            CardHeader("사용량 변화", symbol: "chart.xyaxis.line") {
                                Text(system.historySpanText).font(.callout).foregroundStyle(.secondary)
                            }
                            MemoryChart().frame(minHeight: 200)
                        }
                        .riseIn(1)
                        .gridSpan(2)
                        if let pressure = memory.pressure {
                            Card {
                                CardHeader("메모리 압력", symbol: "gauge.with.dots.needle.67percent")
                                StatusTag(pressure).font(.title3.weight(.semibold))
                                Text(pressure.advice).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            .riseIn(2)
                        }
                        swapCard(memory).riseIn(3)
                        simulatorCard.riseIn(4).gridSpan(2)
                        Card {
                            CardHeader("쓰지 않는 앱", symbol: "moon.zzz") {
                                Text("직접 골라서 종료").font(.callout).foregroundStyle(.secondary)
                            }
                            IdleAppList(apps: system.idleApps, picked: $pickedApps, enabled: run == nil)
                            Text("지금 앞에 있는 앱과 30분 안에 쓴 앱은 빼고, 창 없이 떠 있는 앱부터 보여 줍니다. 아무것도 미리 고르지 않고, 메뉴 막대의 빠른 정리에도 넣지 않습니다. 사용 시각은 Macbak을 켠 뒤부터 셉니다.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .riseIn(5)
                        .gridSpan(2)
                        if !system.orphans.isEmpty {
                            orphanCard.riseIn(5).gridSpan(2)
                        }
                        if !system.idleSessions.isEmpty {
                            sessionCard.riseIn(5).gridSpan(2)
                        }
                        Card {
                            CardHeader("메모리를 많이 쓰는 앱", symbol: "square.stack.3d.up") {
                                Text(system.ownership.note + " · 지금 쓰는 앱은 정리 대상이 아님").font(.callout).foregroundStyle(.secondary)
                            }
                            AppUsageList(apps: system.apps)
                        }
                        .riseIn(6)
                        .gridSpan(2)
                    }
                }
            }
            .readableColumn()
        }
        .floatingBottomBar {
            shutdownBar
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 18)
        }
        .confirmationDialog(confirmTitle, isPresented: $confirming) {
            Button("정리", role: .destructive) { clean(pickedSimulators, chosenApps, chosenOrphans, chosenSessions) }
            Button("취소", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
        .task { await reload() }
        .onAppear {
            system.memoryScreenShown = true
            Task { await system.refreshProcesses() }
        }
        .onDisappear { system.memoryScreenShown = false }
    }

    private var pickedSimulators: [BootedSimulator] { (simulators ?? []).filter { $0.isIdle && picked.contains($0.udid) } }
    private var chosenApps: [AppMemory] { pickedApps.chosen(from: system.idleApps) }
    private var chosenOrphans: [OrphanProcess] { system.orphans.filter { pickedOrphans[$0.pid]?.isSame(as: $0) ?? false } }
    private var chosenSessions: [IdleSession] { system.idleSessions.filter { pickedSessions[$0.id]?.record == $0.record } }

    private var confirmTitle: String {
        [pickedSimulators.isEmpty ? nil : "시뮬레이터 \(pickedSimulators.count)대 끄기", chosenApps.isEmpty ? nil : "앱 \(chosenApps.count)개 종료",
         chosenOrphans.isEmpty ? nil : "개발 도구 \(chosenOrphans.count)개 종료", chosenSessions.isEmpty ? nil : "AI 세션 \(chosenSessions.count)개 끝내기"]
            .compactMap(\.self).joined(separator: " · ")
    }

    private var confirmMessage: String {
        var lines: [String] = []
        if !pickedSimulators.isEmpty {
            lines.append("끌 시뮬레이터: " + pickedSimulators.map(\.name).joined(separator: ", "))
            lines.append("기기와 데이터는 그대로이고 실행 중이던 앱만 닫힙니다. 끄기 직전에 다시 확인합니다.")
        }
        if !chosenApps.isEmpty {
            lines.append("종료할 앱: " + chosenApps.map(\.name).joined(separator: ", "))
            lines.append("저장하지 않은 문서가 있으면 각 앱이 직접 묻습니다. 강제로 종료하지 않습니다.")
        }
        if !chosenOrphans.isEmpty {
            lines.append("종료할 개발 도구: " + chosenOrphans.map(\.name).joined(separator: ", "))
            lines.append("종료 요청만 보내고 강제로 끝내지 않습니다. 보내기 직전에 같은 프로세스인지 다시 확인합니다.")
        }
        if !chosenSessions.isEmpty {
            lines.append("끝낼 AI 세션: " + chosenSessions.map(\.record.name).joined(separator: ", "))
            lines.append("세션을 끝내면 그 작업이 멈춥니다 · 대화 기록은 남습니다. 끝내기 직전에 두 번 다시 읽어 여전히 쉬는지 확인합니다.")
            lines.append("세션이 띄운 보조 프로세스도 함께 끝냅니다. 잠든 채 기다리는 긴 작업도 쉬는 것으로 보일 수 있습니다.")
        }
        return lines.joined(separator: "\n")
    }

    /// Developer tools whose terminal or parent tool is gone. Nothing starts ticked.
    private var orphanCard: some View {
        Card {
            CardHeader("주인 없이 남은 개발 도구", symbol: "terminal") {
                Text("직접 골라서 종료").font(.callout).foregroundStyle(.secondary)
            }
            VStack(spacing: 10) {
                ForEach(system.orphans) { orphan in
                    HStack(spacing: 12) {
                        Toggle(orphan.name, isOn: Binding(
                            get: { pickedOrphans[orphan.pid]?.isSame(as: orphan) ?? false },
                            set: { pickedOrphans[orphan.pid] = $0 ? orphan : nil }
                        ))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .disabled(run != nil)
                        Image(systemName: "terminal").foregroundStyle(.secondary).frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(orphan.name).font(.body).lineLimit(1)
                            Text("주인 없이 " + IdleApp.duration(Date.now.timeIntervalSince(orphan.start)) + "째 실행 중").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 12)
                        Text(orphan.footprint?.memoryText ?? "–").font(.body.monospacedDigit()).frame(width: 72, alignment: .trailing)
                    }
                }
            }
            Text("터미널이나 그것을 띄운 도구가 먼저 끝나 혼자 남은 개발 도구입니다. 개발 도구 위치에 설치된 것만 보여 주고, 서비스로 등록된 것과 10분 안에 시작한 것은 빼고 보여 줍니다.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Claude sessions idle past the Settings age, with what they started. Nothing starts ticked.
    private var sessionCard: some View {
        Card {
            CardHeader("오래 쉬는 AI 세션", symbol: "sparkles") {
                Text("직접 골라서 끝내기").font(.callout).foregroundStyle(.secondary)
            }
            VStack(spacing: 10) {
                ForEach(system.idleSessions) { session in
                    HStack(spacing: 12) {
                        Toggle(session.record.name, isOn: Binding(
                            get: { pickedSessions[session.id]?.record == session.record },
                            set: { pickedSessions[session.id] = $0 ? session : nil }
                        ))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .disabled(run != nil)
                        Image(systemName: "sparkles").foregroundStyle(.secondary).frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.record.name).font(.body).lineLimit(1)
                            Text(IdleApp.duration(Date.now.timeIntervalSince(session.record.updatedAt)) + " 동안 쉼 · 보조 프로세스 \(session.helpers.count)개")
                                .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 12)
                        Text(session.footprint.memoryText).font(.body.monospacedDigit()).frame(width: 72, alignment: .trailing)
                    }
                }
            }
            Text("설정한 시간보다 오래 쉬고, 띄운 프로세스도 모두 쉬는 Claude Code 세션입니다. 진행 중인 작업과 그 뒤에 시작한 프로세스가 있는 세션은 빼고 보여 줍니다.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Memory held for nothing: simulators left booted that no test, debugger or recent launch is using.
    private var simulatorCard: some View {
        Card {
            CardHeader("필요 없이 쓰이는 메모리", symbol: "ipad.and.iphone") {
                if reading {
                    ProgressView().controlSize(.small)
                } else {
                    Button("다시 확인") { Task { await reload() } }
                        .glassAction()
                        .disabled(run != nil)
                }
            }
            if let simulators {
                if simulators.isEmpty {
                    Text("켜진 시뮬레이터가 없습니다.").font(.body).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 10) {
                        ForEach(simulators) { simulator in
                            HStack(spacing: 12) {
                                Toggle(simulator.name, isOn: Binding(
                                    get: { picked.contains(simulator.udid) },
                                    set: { if $0 { picked.insert(simulator.udid) } else { picked.remove(simulator.udid) } }
                                ))
                                .toggleStyle(.checkbox)
                                .labelsHidden()
                                .disabled(!simulator.isIdle || run != nil)
                                .opacity(simulator.isIdle ? 1 : 0)
                                Image(systemName: "ipad.and.iphone").foregroundStyle(.secondary).frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(simulator.name).font(.body).lineLimit(1)
                                    Text(simulator.detail).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 12)
                                Text(simulator.memory.memoryText).font(.body.monospacedDigit())
                            }
                        }
                    }
                }
            } else if !reading {
                Text("사용 여부를 확인하지 못해 아무것도 끄지 않습니다.").font(.body).foregroundStyle(.secondary)
            }
            Text("켜진 채 남은 시뮬레이터를 끕니다. 디버거·테스트가 쓰거나 최근 1시간 안에 쓰인 시뮬레이터는 끄지 않습니다. Xcode·Slack처럼 지금 쓰는 앱은 대상이 아닙니다.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The ticked simulators and apps beside "정리…"; confirming morphs the capsule into the run panel.
    private var shutdownBar: some View {
        let simulators = pickedSimulators
        let apps = chosenApps
        let orphans = chosenOrphans
        let sessions = chosenSessions
        // Each process once, however many chosen groups hold it.
        let groups = apps.map(\.members) + orphans.map { Set([$0.pid]) } + sessions.map(\.members)
        let processBytes = system.processes.map { ProcessOwnership.union(groups, in: $0) } ?? apps.reduce(UInt64(0)) { $0 + $1.total }
        let bytes = simulators.reduce(UInt64(0)) { $0 + $1.memory } + processBytes
        let parts = [simulators.isEmpty ? nil : "시뮬레이터 \(simulators.count)대", apps.isEmpty ? nil : "앱 \(apps.count)개",
                     orphans.isEmpty ? nil : "개발 도구 \(orphans.count)개", sessions.isEmpty ? nil : "AI 세션 \(sessions.count)개"].compactMap(\.self)
        return RunBar(
            actionTitle: "정리…",
            canRun: !parts.isEmpty && run == nil,
            run: run,
            wording: .memoryCleanup,
            total: { UInt64($0).memoryText },
            start: { confirming = true },
            close: {
                withAnimation(reduceMotion ? nil : .bouncy(duration: 0.35)) { run = nil }
                Task { await reload() }
            }
        ) {
            VStack(alignment: .leading, spacing: 1) {
                Text(parts.isEmpty ? "정리할 것이 없습니다" : "약 " + bytes.memoryText)
                    .font(Theme.numeral(20))
                    .monospacedDigit()
                Text(parts.isEmpty ? "쓰지 않는 시뮬레이터나 고른 앱이 여기에 모입니다" : parts.joined(separator: " · ") + " · 지금 차지한 메모리")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func reload() async {
        reading = true
        let found = await Task.detached(priority: .utility) { SimulatorMemory.read() }.value
        simulators = found
        picked = Set(found?.filter(\.isIdle).map(\.udid) ?? [])
        reading = false
    }

    /// Switches the simulators off, asks the apps and then the orphaned tools to quit, and reports the memory change
    /// measured around all of it.
    private func clean(_ simulators: [BootedSimulator], _ apps: [AppMemory], _ orphans: [OrphanProcess], _ sessions: [IdleSession]) {
        withAnimation(reduceMotion ? nil : .bouncy(duration: 0.4)) {
            run = RunProgress(steps: simulators.map(\.runStep) + apps.map(\.runStep) + orphans.map(\.runStep) + sessions.map(\.runStep))
        }
        let sessionEnding = AISessions.Ending.live(idleAge: system.sessionIdleAge)
        Task {
            let before = SystemReader.memory()?.used
            let off = await SimulatorShutdown.switchOff(simulators) { id, problem in mark(id, problem) }
            var closed = 0
            for app in apps {
                // Asked again right before: it may have come back to use while the others were closing.
                guard pickedApps.chosen(from: system.idleApps).contains(where: { $0.id == app.id }) else {
                    mark(app.runStep.id, "그사이 다시 씀")
                    continue
                }
                let outcome = await AppQuitter.quit(app, wait: .seconds(5))
                if outcome == .quit {
                    closed += 1
                    pickedApps.set(app, false)
                }
                mark(app.runStep.id, outcome.reason)
            }
            var ended = 0
            for orphan in orphans {
                let outcome = await OrphanProcesses.end(orphan, using: .live)
                if outcome == .ended {
                    ended += 1
                    pickedOrphans[orphan.pid] = nil
                }
                mark(orphan.runStep.id, outcome.reason)
            }
            var finished = 0
            for session in sessions {
                let outcome = await AISessions.end(session, using: sessionEnding)
                if outcome.rootEnded {
                    finished += 1
                    pickedSessions[session.id] = nil
                }
                mark(session.runStep.id, outcome.reason)
            }
            // Memory is handed back over a few seconds.
            try? await Task.sleep(for: .seconds(3))
            var parts: [String] = []
            if !simulators.isEmpty { parts.append("시뮬레이터 \(off)대 끔") }
            if !apps.isEmpty { parts.append("앱 \(closed)개 종료") }
            if !orphans.isEmpty { parts.append("개발 도구 \(ended)개 종료") }
            if !sessions.isEmpty { parts.append("AI 세션 \(finished)개 끝남") }
            if let before, let after = SystemReader.memory()?.used, before > after { parts.append("메모리 \((before - after).memoryText) 줄어듦 (전후 측정)") }
            withAnimation(reduceMotion ? nil : .smooth) { run?.outcome = parts.joined(separator: " · ") }
            system.refreshAll()
        }
    }

    private func mark(_ id: String, _ problem: String?) {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
            if let problem { run?.problems[id] = problem }
            run?.done += 1
        }
    }

    private func compositionCard(_ memory: MemoryUsage) -> some View {
        Card {
            CardHeader("메모리 구성", symbol: "memorychip") {
                if let pressure = memory.pressure { StatusTag(pressure).font(.callout) }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(memory.used.memoryText)
                    .font(Theme.numeral(40))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(memory.used)))
                Text("/ \(memory.physical.memoryText) 사용 중").font(.title3).foregroundStyle(.secondary)
            }
            SegmentBar(segments: memory.segments, height: 22)
            AdaptiveGrid(minimumColumnWidth: 220, maximumColumns: 3, spacing: 12, fillsRows: false) {
                LegendRow(.blue, title: "앱 메모리", value: memory.app.memoryText, note: "실행 중인 앱이 쓰는 메모리")
                LegendRow(.pink, title: "고정 메모리", value: memory.wired.memoryText, note: "macOS가 늘 붙잡아 두는 메모리")
                LegendRow(.indigo, title: "압축됨", value: memory.compressed.memoryText, note: "자리를 아끼려고 압축해 둔 메모리")
                LegendRow(.gray, title: "캐시된 파일", value: memory.cached.memoryText, note: "필요하면 바로 비울 수 있는 메모리")
                LegendRow(.quaternary, title: "여유", value: memory.free.memoryText)
                if memory.other > 0 {
                    LegendRow(.tertiary, title: "기타", value: memory.other.memoryText, note: "위 항목으로 나누지 못한 나머지")
                }
            }
            Text("사용 중 = 앱 메모리 + 고정 메모리 + 압축됨. 활성 상태 보기(Activity Monitor)와 같은 방식으로 계산한 근사값입니다.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func swapCard(_ memory: MemoryUsage) -> some View {
        Card {
            CardHeader("스왑", symbol: "arrow.left.arrow.right")
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(memory.swapText).font(Theme.numeral(28)).monospacedDigit()
                if memory.swapTotal > 0 {
                    Text("/ \(memory.swapTotal.memoryText)").font(.callout).foregroundStyle(.secondary)
                }
            }
            if memory.swapTotal > 0 {
                SegmentBar(segments: [
                    BarSegment("used", Double(memory.swapUsed), .fillSecondary),
                    BarSegment("free", Double(memory.swapTotal > memory.swapUsed ? memory.swapTotal - memory.swapUsed : 0), .fillQuaternary),
                ], height: 10)
            }
            Text(memory.swapTotal > 0 ? "메모리가 모자라 디스크로 내보낸 양입니다. 늘수록 앱이 느려질 수 있습니다." : "메모리가 충분해서 디스크로 내보낸 메모리가 없습니다.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("압축된 메모리 \(memory.compressed.memoryText)").font(.callout).foregroundStyle(.secondary)
        }
    }
}

/// Unused apps with a checkbox each, the reason each looks unused, and its memory. Nothing starts ticked.
struct IdleAppList: View {
    let apps: [IdleApp]
    @Binding var picked: AppPicks
    let enabled: Bool

    var body: some View {
        if apps.isEmpty {
            Text("지금은 쓰지 않는 앱이 없습니다.").font(.body).foregroundStyle(.secondary)
        } else {
            VStack(spacing: 10) {
                ForEach(apps) { idle in
                    let app = idle.app
                    HStack(spacing: 12) {
                        Toggle(app.name, isOn: Binding(get: { picked.isTicked(idle) }, set: { picked.set(app, $0) }))
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                            .disabled(!enabled)
                        Group {
                            if let icon = app.icon { Image(nsImage: icon).resizable() } else { Image(systemName: "app") }
                        }
                        .frame(width: 24, height: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name).font(.body).lineLimit(1)
                            Text(idle.reason).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 12)
                        Text(app.totalText)
                            .font(.body.monospacedDigit())
                            .frame(width: 72, alignment: .trailing)
                    }
                }
            }
            .animation(.smooth, value: apps.map(\.id))
        }
    }
}

struct AppUsageList: View {
    let apps: [AppMemory]

    var body: some View {
        if apps.isEmpty {
            Text("앱 정보를 읽지 못했습니다.").font(.body).foregroundStyle(.secondary)
        } else {
            let largest = Double(apps.map(\.total).max() ?? 1)
            VStack(spacing: 10) {
                ForEach(apps) { app in
                    HStack(spacing: 12) {
                        Group {
                            if let icon = app.icon { Image(nsImage: icon).resizable() } else { Image(systemName: "app") }
                        }
                        .frame(width: 24, height: 24)
                        Text(app.name).font(.body).lineLimit(1).frame(minWidth: 90, maxWidth: 170, alignment: .leading)
                        MeterBar(fraction: Double(app.total) / largest, tint: .blue)
                        Text(app.totalText)
                            .font(.body.monospacedDigit())
                            .frame(width: 72, alignment: .trailing)
                    }
                }
            }
            .animation(.smooth, value: apps.map(\.total))
        }
    }
}

/// Live used-memory history. Steps once per sample, like Activity Monitor: a smooth scroll every 2 s cost a fifth of a core.
struct MemoryChart: View {
    @Environment(SystemMonitor.self) private var system
    @State private var selectedID: Int?

    private static let gib = 1_073_741_824.0

    var body: some View {
        let history = system.history
        let last = history.last?.id ?? 0
        let ceiling = Double(system.memory?.physical ?? 1) / Self.gib
        let tint = system.memory?.pressure?.tint ?? .blue
        let selected = selectedID.flatMap { id in history.min { abs($0.id - id) < abs($1.id - id) } }

        Chart {
            ForEach(history) { sample in
                AreaMark(x: .value("시점", sample.id), y: .value("사용 중", Double(sample.used) / Self.gib))
                    .foregroundStyle(LinearGradient(colors: [tint.opacity(0.3), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("시점", sample.id), y: .value("사용 중", Double(sample.used) / Self.gib))
                    .foregroundStyle(tint)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    .interpolationMethod(.monotone)
            }
            if let selected {
                RuleMark(x: .value("시점", selected.id))
                    .foregroundStyle(.secondary)
                    .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                        Text(selected.used.memoryText)
                            .font(.callout.monospacedDigit())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .floatingGlass(in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
            }
        }
        // A fixed time window, so new samples enter from the right.
        .chartXScale(domain: (last - SystemMonitor.historyCapacity + 1)...max(last, 1))
        .chartYScale(domain: 0...ceiling)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let gb = value.as(Double.self) { Text("\(Int(gb)) GB").font(.callout) }
                }
            }
        }
        .chartXSelection(value: $selectedID)
        .accessibilityLabel("메모리 사용량 변화")
        .accessibilityValue(system.memory.map { "현재 \($0.used.memoryText)" } ?? "")
    }
}
