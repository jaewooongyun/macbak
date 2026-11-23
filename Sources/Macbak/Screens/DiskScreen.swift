import SwiftUI

/// Everything on this Mac that may be cleaned: Xcode caches, app caches and logs, device files and simulators, and AI
/// tool caches. Only rows that passed every check start ticked.
struct DiskScreen: View {
    @Environment(SystemMonitor.self) private var system
    @Environment(CleanupCoordinator.self) private var cleanup
    @Environment(AIStorage.self) private var storage
    @Environment(AIMonitor.self) private var ai
    @State private var confirmingTrash = false
    @State private var emptyingTrash = false
    /// What the last emptying reported.
    @State private var trashResult: String?

    var body: some View {
        CleanupBoard(
            candidates: cleanup.all + (storage.report?.candidates ?? []),
            title: "정리 후보",
            note: "이 Mac을 실제로 검사해 세 묶음으로 나눴습니다. 여기서는 고른 뒤 \"정리…\"를 눌러야 지웁니다. 클릭 없이 지우는 것은 메뉴 막대의 즉시 정리와 켜 둔 정기 정리뿐이고, 둘 다 얕은 정리 대상만 지웁니다. 지운 파일은 되돌릴 수 없습니다.",
            onFinished: refresh
        ) { selectedBytes in
            VStack(alignment: .leading, spacing: 20) {
                if let disk = system.disk {
                    capacityCard(disk, projected: min(selectedBytes, disk.used))
                }
                if cleanup.explorer.phase != .idle {
                    ExploreCard(phase: cleanup.explorer.phase)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                trashCard
            }
            // Only the card's arrival and departure animate; its progress changes every few seconds and snaps, so the
            // cards around it are not re-laid out and redrawn for each item the model looks at.
            .animation(.smooth, value: cleanup.explorer.phase != .idle)
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
        }
    }

    @ViewBuilder
    private var scanStatus: some View {
        if !cleanup.scanning.isEmpty || storage.scanning {
            ProgressView().controlSize(.small)
            Text("검사하는 중… " + CleanupCoordinator.Area.allCases.filter { cleanup.scanning.contains($0) }.map(\.title).joined(separator: "·"))
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
