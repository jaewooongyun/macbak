import AppKit
import SwiftUI

/// Menu bar title, drawn from the user's menu bar settings. Re-rendered on every sample.
struct MenuBarLabel: View {
    @Environment(SystemMonitor.self) private var system
    @Environment(MenuBarSettings.self) private var settings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: MenuBarGlyph.image(for: settings.content, system: system))
            .accessibilityLabel(MenuBarGlyph.accessibilityText(for: settings.content, system: system))
            .onAppear { if MainWindow.open == nil { MainWindow.open = openWindow } }
    }
}

/// The panel under the menu bar item: a small "한눈에" in rounded modules — the pulse, memory and disk, AI use and
/// quick clean-ups for memory, disk and AI caches — over the app's actions. It sits on the system's menu bar panel
/// material (Liquid Glass on macOS 26).
/// - Important: The panel window is created hidden at launch and only hidden again on close, so `onAppear` comes once.
///   Opening is read from the window itself; that is when AI sampling resumes and a stale storage scan reruns.
struct MenuBarPanel: View {
    /// Whether the panel is open. The monitors keep sampling while it is; the menu bar has no API to ask.
    @MainActor static var isOpen = false

    @Environment(SystemMonitor.self) private var system
    @Environment(LoopScheduler.self) private var loop
    @Environment(AIMonitor.self) private var ai
    @Environment(AIStorage.self) private var storage
    @Environment(CleanupCoordinator.self) private var coordinator
    @Environment(CleanupRunner.self) private var runner
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Booted simulators, read when the panel opens; nil until then or when the read failed.
    @State private var simulators: [BootedSimulator]?
    /// The idle simulators waiting for a last look before switching off.
    @State private var confirmingSimulators: [BootedSimulator]?
    @State private var confirmingTrash = false
    @State private var run: RunProgress?
    /// What `run` is doing, for its wording and units.
    @State private var runKind = RunKind.cleanup

    private enum RunKind { case cleanup, simulators, trash }

    private var popupShown: Bool { confirmingSimulators != nil || confirmingTrash || run != nil }

    /// Only a disk clean-up stops part way; switching simulators off and emptying the Trash are one step each.
    private var stopRun: (() -> Void)? {
        guard runKind == .cleanup else { return nil }
        return { runner.stop() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelModule { pulse }
            HStack(alignment: .top, spacing: 10) {
                if let memory = system.memory { PanelModule { memoryModule(memory) } }
                if let disk = system.disk { PanelModule { diskModule(disk) } }
            }
            .fixedSize(horizontal: false, vertical: true)
            PanelModule { aiModule }
            PanelModule { cleanupModule }
            footer
        }
        .padding(14)
        .frame(width: 340)
        // Popups float over the content, so the menu window keeps its size.
        .overlay {
            if popupShown { Rectangle().fill(.black.opacity(0.18)).transition(.opacity) }
        }
        .overlay { popup }
        .animatesOnlyWhenShown(onChange: panelShown)
    }

    @ViewBuilder
    private var popup: some View {
        Group {
            if let run {
                RunPanel(run: run, wording: runWording, total: runTotal, done: closeRun, stop: stopRun, stopping: runner.isStopping,
                         width: nil, visibleSteps: 4)
            } else if let confirmingSimulators {
                PanelConfirm(title: "시뮬레이터 \(confirmingSimulators.count)대를 끕니다", note: "기기와 데이터는 그대로이고 실행 중이던 앱만 닫힙니다. 끄기 직전에 다시 확인합니다.",
                             rows: confirmingSimulators.map { ($0.udid, $0.name, $0.memory.memoryText) },
                             total: "약 \(confirmingSimulators.reduce(UInt64(0)) { $0 + $1.memory }.memoryText)", action: "끄기", cancel: dismissPopup) {
                    switchOff(confirmingSimulators)
                }
            } else if confirmingTrash {
                PanelConfirm(title: "휴지통을 비웁니다", note: "Finder에 비우기를 요청합니다. 휴지통의 모든 파일이 지워지고 되돌릴 수 없습니다. 처음 한 번은 macOS가 Macbak이 Finder를 제어해도 되는지 묻습니다.",
                             rows: [], total: "늘어난 공간은 비운 뒤 잽니다", action: "비우기", cancel: dismissPopup) {
                    emptyTrash()
                }
            }
        }
        .floatingGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(10)
        .transition(.scale(scale: 0.92).combined(with: .opacity))
        .opacity(popupShown ? 1 : 0)
    }

    // MARK: Modules

    private var pulse: some View {
        let reading = system.vitals.isEmpty ? nil : PulseReading(loads: system.vitals.map(\.load))
        let pressure = system.memory?.pressure
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("맥박").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text("\(reading.map { "\($0.bpm)" } ?? "–") BPM · \(reading?.mood.title ?? "재는 중")")
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            .help(PulseReading.explanation)
            HStack(alignment: .center, spacing: 12) {
                ConcentricVitalRings(vitals: system.vitals, pressure: pressure)
                VitalReadouts(sample: system.vitals.last, pressure: pressure)
            }
        }
    }

    private func memoryModule(_ memory: MemoryUsage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ModuleTitle("메모리", symbol: "memorychip")
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                RollingText(text: memory.used.memoryText, value: Double(memory.used), size: 20)
                Text("/ \(memory.physical.memoryText)").font(.callout).foregroundStyle(.secondary)
            }
            SegmentBar(segments: memory.segments, height: 6, revealOnAppear: false)
            Text("스왑 " + memory.swapText).font(.callout).foregroundStyle(.secondary)
        }
    }

    private func diskModule(_ disk: DiskUsage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ModuleTitle("디스크", symbol: "internaldrive")
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                RollingText(text: disk.available.diskText, value: Double(disk.available), size: 20)
                Text("남음").font(.callout).foregroundStyle(.secondary)
            }
            SegmentBar(segments: [
                BarSegment("used", Double(disk.used), .blue),
                BarSegment("free", Double(disk.available), .fillQuaternary),
            ], height: 6, revealOnAppear: false)
            Text("전체 \(disk.total.diskText)").font(.callout).foregroundStyle(.secondary)
        }
    }

    private var aiModule: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                ModuleTitle("AI 사용량", symbol: Screen.aiActivity.symbol)
                Spacer(minLength: 8)
                if ai.processSampledAt != nil {
                    Text("세션 \(ai.totalSessions)개 · 도구 \(ai.tools.count)개").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if ai.processSampledAt == nil {
                Text("읽는 중…").font(.callout).foregroundStyle(.secondary)
            } else if ai.tools.isEmpty {
                Text("실행 중인 AI 도구가 없습니다").font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(ai.tools.prefix(3)) { usage in
                        HStack(spacing: 8) {
                            Circle().fill(usage.tool.vendor.tint).frame(width: 8, height: 8)
                            Text(usage.tool.name).lineLimit(1)
                            Spacer(minLength: 8)
                            Text("CPU " + usage.cpu.percentText).foregroundStyle(.secondary)
                            Text(usage.memory.memoryText).frame(width: 64, alignment: .trailing)
                        }
                        .font(.callout.monospacedDigit())
                    }
                }
            }
            if let conversations { Text(conversations).font(.callout).foregroundStyle(.secondary) }
        }
    }

    /// Conversations touched lately, from log file modification times only; nil before the first read.
    private var conversations: String? {
        guard let sessions = ai.activity?.sessions.values else { return nil }
        return "최근 대화 · 1시간 \(sessions.reduce(0) { $0 + $1.within1h })개 · 24시간 \(sessions.reduce(0) { $0 + $1.within24h })개"
    }

    private var cleanupModule: some View {
        VStack(alignment: .leading, spacing: 10) {
            ModuleTitle("정리", symbol: "sparkles")
            shallowSection
            Divider()
            deepRow
            Divider()
            reliefRow
            Divider()
            trashRow
        }
    }

    /// Every row a curated source vouches for, from each scan whose result is still fresh enough to act on. The two are
    /// judged apart: the AI storage scan the panel reruns on opening must not empty the disk rows while it reads.
    private var shallow: [CleanupCandidate] {
        ((coordinator.isStale ? [] : coordinator.all) + (storage.isStale ? [] : storage.report?.candidates ?? [])).filter(\.isShallow)
    }

    /// The immediate clean-up: one button and no list to confirm, because only caches the rules know come back by
    /// themselves are in it; the executor still checks each one just before deleting. The panel never starts a scan by
    /// itself (a full one takes a minute or two), so an old or missing result asks for one.
    private var shallowSection: some View {
        let items = shallow
        let bytes = items.reduce(Int64(0)) { $0 + $1.bytes }
        // Only the disk scan holds the section up: it is what the button waits for. The AI storage scan the panel starts
        // on opening runs beside it and adds its rows when done; it once replaced the button for a minute or more.
        let scanning = !coordinator.scanning.isEmpty
        let stale = coordinator.isStale
        let status = if scanning {
            "검사하는 중…"
        } else if coordinator.scannedAt == nil {
            "아직 검사하지 않음"
        } else if stale {
            "검사한 지 10분 넘음"
        } else {
            "\(items.count)개 · 검사 " + (coordinator.scannedAt?.formatted(.relative(presentation: .named)) ?? "")
                + (storage.scanning ? " · AI 확인 중" : "")
        }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label("얕은 정리", systemImage: "bolt").font(.body.weight(.medium))
                Spacer(minLength: 8)
                Text(status).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Text("규칙이 다시 생긴다고 확인한 캐시만, 확인 없이 바로 지웁니다.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Group {
                if scanning {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                } else if stale {
                    Button { Task { await coordinator.scan() }; Task { await scanIfStale() } } label: {
                        Label(coordinator.scannedAt == nil ? "검사" : "다시 검사", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                    }
                    .glassAction()
                } else {
                    Button { performCleanup(items) } label: {
                        Text(items.isEmpty ? "지금 바로 지울 것 없음" : "즉시 정리 · \(bytes.diskText)").frame(maxWidth: .infinity)
                    }
                    .prominentAction()
                    .disabled(items.isEmpty || runner.isRunning || popupShown)
                }
            }
            .controlSize(.large)
        }
        .help(Self.shallowHelp(coordinator.ages))
    }

    /// What the immediate clean-up takes, in the ages picked in Settings.
    static func shallowHelp(_ ages: CleanupAges) -> String {
        "\(ages.appCache)일 넘게 안 쓴 앱 캐시 중 규칙이 알아보는 것(앱·컨테이너·Chromium 앱), \(ages.buildCache)일 넘게 안 쓴 Xcode 빌드 캐시, "
            + "\(ages.deviceSupportShallow)일 넘게 안 쓴 기기 지원 파일, \(ages.logs)일 넘은 로그, AI 도구가 다시 만드는 캐시, "
            + "내려받지 않고 다시 만드는 개발 도구 캐시. 시뮬레이터는 넣지 않습니다. 정기 정리도 같은 것만 지웁니다. 기간은 설정의 '정리 기준'에서 바꿉니다."
    }

    /// What only the dashboard offers — rows that need a choice or that no curated source vouches for — and what the
    /// on-device model is doing with them.
    private var deepRow: some View {
        let more = (coordinator.all + (storage.report?.candidates ?? [])).filter { $0.isSelectable && !$0.isShallow }
        let bytes = more.reduce(Int64(0)) { $0 + $1.bytes }
        let suggested = more.filter { $0.aiEvidence != nil }.count
        let detail: String = switch coordinator.explorer.phase {
        case .exploring(let done, let total, _): "기기 AI가 살펴보는 중 \(done)/\(total)"
        default:
            if coordinator.scannedAt == nil {
                "대시보드에서 하나씩 보고 고릅니다"
            } else if more.isEmpty {
                "더 고를 것 없음"
            } else {
                "\(more.count)개 · \(bytes.diskText)" + (suggested > 0 ? " · 기기 AI 제안 \(suggested)개" : "")
            }
        }
        return ActionRow(symbol: "square.stack.3d.up", title: "깊은 정리", detail: detail) {
            Button("대시보드…") { openDashboard(.disk) }
                .disabled(popupShown)
        }
    }

    /// Opens the main window on a screen, whether it was open or not.
    private func openDashboard(_ screen: Screen) {
        navigation.requested = screen
        openWindow(id: "main")
        NSApp.activate()
    }

    /// The Trash, emptied by Finder on request. Its size stays unknown beforehand: macOS keeps the Trash private.
    private var trashRow: some View {
        ActionRow(symbol: "trash", title: "휴지통", detail: "Finder가 비움 · 되돌릴 수 없음") {
            Button("비우기…") { withAnimation(reduceMotion ? nil : .bouncy(duration: 0.35)) { confirmingTrash = true } }
                .disabled(popupShown)
        }
    }

    private var runWording: RunWording {
        switch runKind {
        case .cleanup: .cleanup
        case .simulators: .shutdownSimulators
        case .trash: .emptyTrash
        }
    }

    private func runTotal(_ amount: Double) -> String {
        switch runKind {
        case .cleanup: Int64(amount).diskText
        case .simulators: UInt64(amount).memoryText
        case .trash: "–"
        }
    }

    /// Simulators left booted that nothing uses; the apps you work in are never offered.
    private var reliefRow: some View {
        let idle = (simulators ?? []).filter(\.isIdle)
        let bytes = idle.reduce(UInt64(0)) { $0 + $1.memory }
        let detail = simulators == nil ? "확인하는 중…" : idle.isEmpty ? "쓰지 않는 시뮬레이터 없음" : "쓰지 않는 시뮬레이터 \(idle.count)대 · 약 \(bytes.memoryText)"
        return ActionRow(symbol: "memorychip", title: "메모리", detail: detail) {
            Button("끄기…") { withAnimation(reduceMotion ? nil : .bouncy(duration: 0.35)) { confirmingSimulators = idle } }
                .disabled(idle.isEmpty || popupShown)
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.secondary)
                    .symbolEffect(.bounce, value: loop.lastRun?.id)
                Text(nextRunText).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if loop.isChecking {
                    // While the loop deletes (not while it scans, nor while it waits for a screen's run), its run can be
                    // stopped like one started here.
                    if runner.isRunning, runner.isLoopRun {
                        Button(runner.isStopping ? "멈추는 중…" : "중단") { runner.stop() }
                            .glassAction()
                            .controlSize(.small)
                            .disabled(runner.isStopping)
                    }
                    ProgressView().controlSize(.small)
                }
            }
            .font(.callout)
            HStack(spacing: 8) {
                Button("Macbak 열기") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                .prominentAction()
                // The panel does not activate the app, so Settings would otherwise open behind other windows.
                Button("설정…") {
                    NSApp.activate()
                    openSettings()
                }
                .glassAction()
                Spacer()
                Button("종료") { NSApp.terminate(nil) }
                    .glassAction()
                    .keyboardShortcut("q")
            }
        }
        .padding(.horizontal, 4)
    }

    private var nextRunText: String {
        if loop.isChecking { return "정기 정리 중…" }
        guard let next = loop.nextRun else { return "정기 정리 꺼짐" }
        return "다음 정기 정리 \(next.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
    }

    // MARK: Actions

    private func panelShown(_ shown: Bool) {
        Self.isOpen = shown
        guard shown else {
            // A confirmation or picker left open must not wait for the next opening.
            confirmingSimulators = nil
            confirmingTrash = false
            if run?.finished == true { run = nil }
            return
        }
        system.refreshAll()
        Task { await scanIfStale() }
        Task { await readSimulators() }
    }

    /// Samples AI processes first: a scan without them cannot tell which caches are unused and would mark none ready.
    private func scanIfStale() async {
        await ai.wake()
        if ai.runningToolIDs != nil, storage.isStale { await storage.scan(using: ai) }
    }

    private func dismissPopup() {
        withAnimation(reduceMotion ? nil : .bouncy(duration: 0.35)) {
            confirmingSimulators = nil
            confirmingTrash = false
        }
    }

    /// Deletes for real through the same executor as the window; the runner drops deleted rows from both lists.
    private func performCleanup(_ items: [CleanupCandidate]) {
        withAnimation(reduceMotion ? nil : .bouncy(duration: 0.4)) {
            runKind = .cleanup
            run = RunProgress(steps: items.map(\.runStep))
        }
        Task {
            let report = await runner.run(items, shallow: true) { result in
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
                    if !result.outcome.succeeded, let reason = result.outcome.reason { run?.problems[result.id] = reason }
                    run?.done += 1
                }
            }
            withAnimation(reduceMotion ? nil : .smooth) {
                if let refusal = report.refusal {
                    run?.problems = Dictionary(uniqueKeysWithValues: items.map { ($0.id, refusal) })
                    run?.done = items.count
                }
                run?.outcome = report.refusal ?? report.gainText
            }
            system.refreshAll()
        }
    }

    private func readSimulators() async {
        simulators = await Task.detached(priority: .utility) { SimulatorMemory.read() }.value
    }

    private func switchOff(_ chosen: [BootedSimulator]) {
        guard !chosen.isEmpty else { return }
        withAnimation(reduceMotion ? nil : .bouncy(duration: 0.4)) {
            confirmingSimulators = nil
            runKind = .simulators
            run = RunProgress(steps: chosen.map(\.runStep))
        }
        Task {
            let outcome = await SimulatorShutdown.run(chosen) { id, problem in
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
                    if let problem { run?.problems[id] = problem }
                    run?.done += 1
                }
            }
            withAnimation(reduceMotion ? nil : .smooth) { run?.outcome = outcome }
            system.refreshAll()
            await readSimulators()
        }
    }

    private func emptyTrash() {
        withAnimation(reduceMotion ? nil : .bouncy(duration: 0.4)) {
            confirmingTrash = false
            runKind = .trash
            run = RunProgress(steps: [RunStep(id: "trash", name: "휴지통", icon: .symbol("trash"), amount: 0, amountText: "–")])
        }
        Task {
            let result = await Task.detached(priority: .userInitiated) { TrashEmptier.live().run() }.value
            withAnimation(reduceMotion ? nil : .smooth) {
                if !result.emptied { run?.problems["trash"] = result.message }
                run?.done = 1
                run?.outcome = result.message
            }
            system.refreshAll()
        }
    }

    private func closeRun() {
        withAnimation(reduceMotion ? nil : .bouncy(duration: 0.35)) { run = nil }
    }
}

/// The last look before acting from the panel: what goes and how much, and what it means.
private struct PanelConfirm: View {
    let title: String
    let note: String
    let rows: [(id: String, name: String, amount: String)]
    let total: String
    let action: String
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: "checkmark.shield").font(.headline)
            Text(note)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(rows.prefix(5), id: \.id) { row in
                    HStack {
                        Text(row.name).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(row.amount).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                if rows.count > 5 { Text("외 \(rows.count - 5)개").foregroundStyle(.secondary) }
            }
            .font(.callout)
            HStack {
                Text(total).font(.callout.weight(.semibold))
                Spacer()
                Button("취소", action: cancel)
                    .glassAction()
                    .keyboardShortcut(.cancelAction)
                Button(action, role: .destructive, action: confirm)
                    .prominentAction()
                    .tint(.red)
            }
        }
        .padding(18)
    }
}

/// One rounded group on the panel, like a Control Center module.
private struct PanelModule<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.fillQuaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct ModuleTitle: View {
    let title: String
    let symbol: String

    init(_ title: String, symbol: String) {
        self.title = title
        self.symbol = symbol
    }

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

/// A clean-up on one line: what it is, how much, and the button that plays it.
private struct ActionRow<Action: View>: View {
    let symbol: String
    let title: String
    let detail: String
    @ViewBuilder let action: Action

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            action
                .glassAction()
                .controlSize(.small)
        }
    }
}
