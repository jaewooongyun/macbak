import AppKit
import Observation

/// Owns the disk clean-up candidates the window and the menu bar show. One scan at a time; every finished scan moves
/// `generation` on, and a selection made against an older generation is refused at deletion time.
/// - Note: AI tool caches stay with `AIStorage`, which the AI screens already use; this covers everything else.
@MainActor
@Observable
final class CleanupCoordinator {
    enum Area: String, CaseIterable, Sendable {
        case xcode, appCaches, devices, general

        var title: String {
            switch self {
            case .xcode: "Xcode 캐시"
            case .appCaches: "앱 캐시·로그"
            case .devices: "기기 지원·시뮬레이터"
            case .general: "개발 도구·기타 캐시"
            }
        }
    }

    private(set) var candidates: [Area: [CleanupCandidate]] = [:]
    private(set) var scanning: Set<Area> = []
    private(set) var scannedAt: Date?
    private(set) var generation = 0
    /// Snapshots and tests fill the candidates themselves and must never scan the real disk.
    private let scansDisk: Bool
    /// The scan in progress, which later callers wait for.
    @ObservationIgnored private var current: Task<Void, Never>?
    /// Looks at the rows the rules could not tell, after each scan.
    let explorer: CacheExplorer
    /// Whether a clean-up is deleting now. A scan waits for it to finish, so no new hold or verdict lands on rows a run
    /// was handed; together with the runner waiting for a scan in progress, scans and runs never overlap.
    @ObservationIgnored var isDeleting: @MainActor () -> Bool = { false }

    init() {
        scansDisk = true
        explorer = CacheExplorer()
    }

    init(fixture: [Area: [CleanupCandidate]], explorer: CacheExplorer = CacheExplorer()) {
        candidates = fixture
        scannedAt = .now
        scansDisk = false
        self.explorer = explorer
    }

    var all: [CleanupCandidate] { Area.allCases.flatMap { candidates[$0] ?? [] } }
    var isStale: Bool { scansDisk && (scannedAt.map { Date.now.timeIntervalSince($0) > CleanupCandidate.resultLifetime } ?? true) }

    /// Scans every area. A call while a scan runs waits for that scan rather than returning at once, so the caller
    /// never reads half-filled results.
    func scan() async {
        while isDeleting() {
            // A cancelled sleep throws at once; ignoring it would spin the main actor. The caller no longer wants the scan.
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
        }
        guard scansDisk else { return }
        if let current { return await current.value }
        let task = Task { [self] in
            await scanAll()
            current = nil
        }
        current = task
        await task.value
    }

    private func scanAll() async {
        explorer.cancel()
        scanning = Set(Area.allCases)
        let context = await makeContext()
        await withTaskGroup(of: (Area, [CleanupCandidate]).self) { group in
            for area in Area.allCases {
                group.addTask(priority: .utility) { (area, Self.scan(area, context)) }
            }
            for await (area, found) in group {
                candidates[area] = found.map { row in
                    var row = row
                    row.scannedAt = context.now
                    return row
                }.sorted(by: Self.oldestFirst)
                scanning.remove(area)
            }
        }
        // The start, as on each row: the panel's "too old" and the executor's must agree.
        scannedAt = context.now
        generation += 1
        startExploring()
    }

    /// Hands the rows the rules could not tell to the on-device model, in this scan's generation.
    func startExploring() {
        // Rows held for a veto first: they are waiting to be ticked.
        let pending = all.compactMap { row in row.exploreInput.map { (id: row.id, input: $0) } }
            .sorted { $0.input.role == .veto && $1.input.role == .offer }
        let scanGeneration = generation
        explorer.explore(pending) { [weak self] id, finding in
            guard let self, self.generation == scanGeneration else { return }
            self.apply(finding, to: id)
        }
        // No model on this Mac: nothing will object, so the person's rules decide alone.
        if case .unavailable = explorer.phase { releaseHolds() }
    }

    /// Waits, at most five minutes, until the on-device model has looked at this scan's rows, so app caches held for its
    /// veto are decided before the loop cleans; a row still held then stays out. Well inside the 10-minute result life.
    func explored() async {
        let deadline = Date.now.addingTimeInterval(300)
        while case .exploring = explorer.phase, Date.now < deadline {
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
        }
    }

    /// Waits for a scan in progress, so a run starts on settled verdicts.
    func settled() async {
        if let current { await current.value }
    }

    /// Puts what the on-device model saw on its row, in whichever area it is.
    func apply(_ finding: CacheExplorer.Finding, to id: String) {
        for area in Area.allCases {
            guard let index = candidates[area]?.firstIndex(where: { $0.id == id }), let row = candidates[area]?[index] else { continue }
            candidates[area]?[index] = Self.applying(finding, to: row)
            return
        }
    }

    /// An offer only makes a row the rules could not tell a choice; a veto only protects an app cache the 3-day rule
    /// ticked. Either way the row's own checks (in use, changed recently, could not be read) still apply, and the model
    /// never ticks anything.
    nonisolated static func applying(_ finding: CacheExplorer.Finding, to row: CleanupCandidate) -> CleanupCandidate {
        var evidence = row.evidence
        switch row.exploreInput?.role ?? .offer {
        case .offer:
            if finding.offered {
                evidence.protectedReason = nil
                evidence.downloadCost = true
                evidence.costReason = "기기 AI가 다시 만들어지는 캐시로 봤습니다. 내용을 확인하고 고르세요."
            } else {
                evidence.protectedReason = finding.decision == "userData"
                    ? "기기 AI가 사용자 데이터로 봤습니다." : "기기 AI도 지워도 되는지 판단하지 못했습니다."
            }
        case .veto:
            evidence.awaitingModel = false
            guard finding.vetoes else { return row.with(evidence: evidence, aiEvidence: row.aiEvidence) }
            evidence.protectedReason = "기기 AI가 사용자 데이터나 설정으로 봤습니다."
        }
        return row.with(evidence: evidence, aiEvidence: finding.evidence.isEmpty ? nil : finding.evidence)
    }

    /// Lets go of every row held for the model's veto, as when the model cannot run here.
    private func releaseHolds() {
        for area in Area.allCases {
            candidates[area] = candidates[area]?.map { row in
                guard row.evidence.awaitingModel else { return row }
                var evidence = row.evidence
                evidence.awaitingModel = false
                return row.with(evidence: evidence, aiEvidence: row.aiEvidence)
            }
        }
    }

    /// Drops rows a clean-up deleted, so lists are right without a full rescan.
    func forget(_ ids: Set<String>) {
        for area in Area.allCases { candidates[area]?.removeAll { ids.contains($0.id) } }
    }

    nonisolated private static func scan(_ area: Area, _ context: ScanContext) -> [CleanupCandidate] {
        switch area {
        case .xcode: XcodeCacheScanner.scan(context)
        case .appCaches: AppCacheScanner.scan(context)
        case .devices: DeveloperDeviceScanner.scan(context)
        case .general: GeneralCacheScanner.scan(context)
        }
    }

    /// Oldest use first, unknown last; size never decides the order.
    nonisolated static func oldestFirst(_ a: CleanupCandidate, _ b: CleanupCandidate) -> Bool {
        switch (a.lastUsed, b.lastUsed) {
        case let (x?, y?): x < y
        case (_?, nil): true
        default: false
        }
    }

    private func makeContext() async -> ScanContext {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home.appending(path: "Library/Caches").path(percentEncoded: false))) ?? []
        let installed = Set(names.filter { $0.contains(".") && NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil })
        let openFiles = await Task.detached(priority: .utility) { OpenFiles.capture() }.value
        return ScanContext(home: home, now: .now, openFiles: openFiles, runningBundleIDs: running, installedBundleIDs: installed)
    }
}
