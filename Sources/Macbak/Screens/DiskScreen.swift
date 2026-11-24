import SwiftUI

/// Everything on this Mac that may be cleaned: Xcode caches, app caches and logs, device files and simulators, and AI
/// tool caches. Only rows that passed every check start ticked.
struct DiskScreen: View {
    @Environment(SystemMonitor.self) private var system
    @Environment(CleanupCoordinator.self) private var cleanup
    @Environment(AIStorage.self) private var storage
    @Environment(AIMonitor.self) private var ai
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmingTrash = false
    @State private var emptyingTrash = false
    /// What the last emptying reported.
    @State private var trashResult: String?

    var body: some View {
        CleanupBoard(
            candidates: cleanup.all + (storage.report?.candidates ?? []),
            title: "정리 후보",
            note: "이 Mac을 실제로 검사해 세 묶음으로 나눴습니다. 여기서는 고른 뒤 \"정리…\"를 눌러야 지웁니다. 클릭 없이 지우는 것은 메뉴 막대의 즉시 정리와 켜 둔 정기 정리뿐이고, 둘 다 얕은 정리 대상만 지웁니다. 지운 파일은 되돌릴 수 없습니다.",
            scanning: !cleanup.scanning.isEmpty || storage.scanning,
            onFinished: refresh
        ) { selectedBytes in
            VStack(alignment: .leading, spacing: 20) {
                if let disk = system.disk {
                    capacityCard(disk, projected: min(selectedBytes, disk.used))
                }
                if let brief {
                    summaryCard(cleanup.narrator.narration(for: brief))
                }
                if cleanup.explorer.phase != .idle {
                    ExploreCard(phase: cleanup.explorer.phase)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                trashCard
            }
            // Only the card's arrival and departure animate; its progress changes every few seconds and snaps, so the
            // cards around it are not re-laid out and redrawn for each item the model looks at.
            .animation(reduceMotion ? nil : Theme.stateChange, value: cleanup.explorer.phase != .idle)
        }
        // The usual and the expanded scan together, when either result is old; the coordinator decides.
        .task {
            await cleanup.scanEverything()
        }
        .task {
            if storage.isStale {
                await ai.wake()
                await storage.scan(using: ai)
            }
        }
        // Once per set of facts, after every scan and the explorer; leaving the screen cancels it.
        .task(id: askKey) {
            if askKey != nil { await cleanup.summarize { brief } }
        }
    }

    /// The summary's facts, from the same rows the board lists; nil until the disk is read and the usual scan is done.
    private var brief: DiskNarrator.Brief? {
        guard let disk = system.disk, cleanup.scannedAt != nil,
              !CleanupCoordinator.Area.regular.contains(where: cleanup.scanning.contains) else { return nil }
        return DiskNarrator.brief(rows: cleanup.all + (storage.report?.candidates ?? []), disk: disk,
                                  environment: cleanup.environment, discovery: cleanup.discovery)
    }

    /// When the model may be asked: no scan runs and the explorer is done.
    private var askKey: DiskNarrator.Brief.Key? {
        guard cleanup.scanning.isEmpty, !storage.scanning, !cleanup.explorer.isExploring else { return nil }
        return brief?.key
    }

    private func summaryCard(_ narration: DiskNarrator.Narration) -> some View {
        Card {
            CardHeader("디스크 요약", symbol: "text.alignleft") {
                Text(narration.byModel ? "기기 AI가 고른 요약 · 숫자는 검사 결과" : "검사 결과 요약")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(narration.headline.text).font(.headline)
            ForEach(narration.facts) { fact in
                Text(fact.text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            askAll
        }
    }

    /// The folders nothing could tell, largest first, handed to the on-device model in one click.
    @ViewBuilder
    private var askAll: some View {
        let askable = cleanup.askable.count
        if let progress = cleanup.advisor.progress {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("판단하지 못한 폴더를 기기 AI가 살펴보는 중 \(progress.done)/\(progress.total)")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        } else if askable > 0 {
            Button("판단하지 못한 폴더를 기기 AI에게 묻기 (큰 것부터 \(min(askable, RuleAdvisor.batchLimit))개)") { cleanup.ask() }
                .glassAction()
            // The rows may sit in a folded group: why the last asking got no answer shows here too.
            if let reason = cleanup.askable.lazy.compactMap({ row -> String? in
                guard let input = row.askInput, case .unavailable(let reason)? = cleanup.advisor.answer(for: row.id, input: input) else { return nil }
                return reason
            }).first {
                Text(reason).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    /// The Trash, emptied by Finder on request. Its size stays unknown beforehand: macOS keeps the Trash private.
    private var trashCard: some View {
        Card {
            CardHeader("휴지통", symbol: "trash") {
                if emptyingTrash { ProgressView().controlSize(.small) }
                Button("비우기…") { confirmingTrash = true }
                    .glassAction()
                    .disabled(emptyingTrash)
            }
            Text(trashResult ?? "Finder에 비우기를 요청합니다. 휴지통 안은 macOS가 보호해서 크기를 미리 읽지 않고, 비운 뒤 늘어난 공간을 재서 보여 줍니다.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .confirmationDialog("휴지통을 비울까요?", isPresented: $confirmingTrash) {
            Button("비우기", role: .destructive, action: emptyTrash)
            Button("취소", role: .cancel) {}
        } message: {
            Text("휴지통의 모든 파일이 지워지고 되돌릴 수 없습니다. 처음 한 번은 macOS가 Macbak이 Finder를 제어해도 되는지 묻습니다.")
        }
    }

    private func emptyTrash() {
        emptyingTrash = true
        trashResult = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) { TrashEmptier.live().run() }.value
            trashResult = result.message
            emptyingTrash = false
            system.refreshAll()
        }
    }

    private func capacityCard(_ disk: DiskUsage, projected: Int64) -> some View {
        Card {
            CardHeader(disk.name, symbol: "internaldrive") {
                scanStatus
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(disk.available.diskText).font(Theme.numeral(40)).monospacedDigit()
                Text("사용 가능 · 전체 \(disk.total.diskText)").font(.title3).foregroundStyle(.secondary)
            }
            SegmentBar(segments: [
                BarSegment("used", Double(disk.used - projected), .blue),
                BarSegment("projected", Double(projected), .blue.opacity(0.45), striped: true),
                BarSegment("free", Double(disk.available), .fillQuaternary),
            ], height: 22)
            AdaptiveGrid(minimumColumnWidth: 220, maximumColumns: 3, spacing: 12, fillsRows: false) {
                LegendRow(.blue, title: "사용 중", value: disk.used.diskText)
                LegendRow(.blue.opacity(0.45), striped: true, title: "고른 항목", value: projected.diskText, note: "폴더 크기 합계 · 실제로 늘어나는 공간은 더 작을 수 있음")
                LegendRow(.quaternary, title: "사용 가능", value: disk.available.diskText, note: "\(disk.purgeable.diskText)는 macOS가 필요할 때 비움")
            }
            discoveryNote
            if let text = Self.environmentText(cleanup.environment) {
                Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    /// What the scan found this Mac is used for, in one line; nil before a scan or when nothing was found.
    static func environmentText(_ environment: WorkEnvironment?) -> String? {
        guard let environment, !environment.kinds.isEmpty else { return nil }
        return "이 Mac에서 찾은 작업: " + environment.summary
    }

    @ViewBuilder
    private var scanStatus: some View {
        if !cleanup.scanning.isEmpty || storage.scanning {
            ProgressView().controlSize(.small)
            Text("검사하는 중… 남은 영역 \(cleanup.scanning.filter { $0.applies(to: cleanup.environment) }.count + (storage.scanning ? 1 : 0))곳")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            if let scannedAt = cleanup.scannedAt {
                Text("검사 \(scannedAt.formatted(.relative(presentation: .named)))").font(.callout).foregroundStyle(.secondary)
            }
            Button("다시 검사", action: rescan)
                .glassAction()
        }
    }

    @ViewBuilder
    private var discoveryNote: some View {
        if let text = Self.discoveryText(scanningProjects: cleanup.scanning.contains(.projects), discovery: cleanup.discovery) {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .help(cleanup.discovery?.skipped.joined(separator: "\n") ?? "")
        }
    }

    /// While the expanded scan walks the home, what it does and how long it takes; after it, what it did not look at and
    /// whether it ran out of time; nil before any.
    static func discoveryText(scanningProjects: Bool, discovery: ProjectDiscovery.Result?) -> String? {
        if scanningProjects { return "홈 폴더의 프로젝트까지 찾는 중입니다. 3~4분 걸리고, 찾는 대로 목록에 더합니다." }
        guard let discovery else { return nil }
        return (discovery.partial ? "프로젝트 검사는 시간이 다 돼 일부만 봤습니다. " : "") + "검사하지 않은 곳: " + discovery.skipped.joined(separator: " · ")
    }

    /// Both scans again, the expanded one too, whatever their age.
    private func rescan() {
        system.refreshAll()
        Task { await cleanup.scanEverything(force: true) }
        Task {
            await ai.wake()
            await storage.scan(using: ai)
        }
    }

    /// After a clean-up: the usual scan and the AI storage again. Deleted rows are already gone from every list, so the
    /// minutes-long walk runs again only once its result is old, or on "다시 검사".
    private func refresh() {
        system.refreshAll()
        Task { await cleanup.scan() }
        Task {
            await ai.wake()
            await storage.scan(using: ai)
        }
    }
}
