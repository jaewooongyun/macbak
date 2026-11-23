import AppKit
import Observation

/// Owns the disk clean-up candidates the window and the menu bar show. One scan at a time; every finished scan moves
/// `generation` on, and a selection made against an older generation is refused at deletion time.
/// - Note: AI tool caches stay with `AIStorage`, which the AI screens already use; this covers everything else.
@MainActor
@Observable
final class CleanupCoordinator {
    enum Area: String, CaseIterable, Sendable {
        case xcode, appCaches, devices, general, runtimes, projects, jobs

        /// What `scan()` reads: the loop, the menu and the dashboard.
        static let regular: [Area] = [.xcode, .appCaches, .devices, .general]
        /// What only `scanProjects()` reads: slow, or outside the usual places.
        static let expanded: [Area] = [.runtimes, .projects, .jobs]

        var title: String {
            switch self {
            case .xcode: "Xcode 캐시"
            case .appCaches: "앱 캐시·로그"
            case .devices: "기기 지원·시뮬레이터"
            case .general: "개발 도구·기타 캐시"
            case .runtimes: "시뮬레이터 런타임"
            case .projects: "프로젝트 안 빌드 캐시"
            case .jobs: "끝난 AI 작업 임시 파일"
            }
        }
    }

    /// What a scan reads; tests replace it to hold a scan open or to count what it calls.
    struct Scanning: Sendable {
        var area: @Sendable (Area, ScanContext) -> [CleanupCandidate] = { CleanupCoordinator.scan($0, $1) }
        var context: @MainActor @Sendable (CleanupAges) async -> ScanContext = { await CleanupCoordinator.liveContext(ages: $0) }
        /// The expanded scan's walk of the home.
        var discover: @Sendable (ScanContext) -> ProjectDiscovery.Result = { ProjectDiscovery.walk(home: $0.home) }
        /// The usual build-cache rows of the workspaces holding these caches, their package checkouts proven again.
        /// - Important: The only place that turns re-proving on; the loop and the menu never reach it.
        var reprove: @Sendable (ScanContext, Set<String>) -> [CleanupCandidate] = { XcodeCacheScanner.scan($0, only: $1, reprove: true) }
    }

    /// What the expanded scan proved of a usual build-cache row: its alarm cleared by re-proving its package checkouts.
    /// Applied to the usual row only while it still has these targets, this last use and this protection, so a later
    /// usual scan that finds it open, recently used or protected otherwise wins.
    struct ReproofLift: Equatable, Sendable {
        let targets: [CleanupTarget]
        let lastUsed: Date?
        let reason: String
    }

    private(set) var candidates: [Area: [CleanupCandidate]] = [:]
    private(set) var scanning: Set<Area> = []
    private(set) var scannedAt: Date?
    /// The ages the latest finished scan judged by.
    private(set) var scannedAges: CleanupAges?
    private(set) var generation = 0
    /// When the latest expanded scan started; nil before one, or when Settings changed while it read.
    private(set) var projectsScannedAt: Date?
    /// What the latest expanded scan's walk skipped and whether it finished.
    private(set) var discovery: ProjectDiscovery.Result?
    /// Usual rows the expanded scan proved again, by id; dropped once that scan is older than the result lifetime.
    private(set) var lifts: [String: ReproofLift] = [:]
    /// The ages picked in Settings; nil keeps the defaults.
    let settings: CleanupSettings?
    @ObservationIgnored private let sources: Scanning
    /// Snapshots and tests fill the candidates themselves and must never scan the real disk.
    private let scansDisk: Bool
    /// The scan in progress, which later callers wait for.
    @ObservationIgnored private var current: Task<Void, Never>?
    /// The expanded scan in progress, likewise.
    @ObservationIgnored private var projectsTask: Task<Void, Never>?
    /// Looks at the rows the rules could not tell, after each scan.
    let explorer: CacheExplorer
    /// Whether a clean-up is deleting now. A scan waits for it to finish, so no new hold or verdict lands on rows a run
    /// was handed; together with the runner waiting for a scan in progress, scans and runs never overlap.
    @ObservationIgnored var isDeleting: @MainActor () -> Bool = { false }

    init(settings: CleanupSettings? = nil, scanning: Scanning = Scanning()) {
        scansDisk = true
        explorer = CacheExplorer()
        self.settings = settings
        sources = scanning
    }

    init(fixture: [Area: [CleanupCandidate]], explorer: CacheExplorer = CacheExplorer()) {
        candidates = fixture
        scannedAt = .now
        scansDisk = false
        self.explorer = explorer
        settings = nil
        sources = Scanning()
    }

    var ages: CleanupAges { settings?.ages ?? CleanupAges() }
    var all: [CleanupCandidate] { Area.allCases.flatMap(rows(in:)) }

    /// An area's rows as screens and runs see them: a usual build-cache row the expanded scan proved again, while that
    /// scan is fresh and the row is unchanged, is a choice only (`manualOnly`, `reproved`) instead of protected.
    func rows(in area: Area) -> [CleanupCandidate] {
        let rows = candidates[area] ?? []
        guard area == .xcode, !lifts.isEmpty,
              let at = projectsScannedAt, Date.now.timeIntervalSince(at) <= CleanupCandidate.resultLifetime else { return rows }
        return rows.map { row in
            guard let lift = lifts[row.id], lift.targets == row.targets, lift.lastUsed == row.lastUsed,
                  row.evidence.protectedReason == lift.reason else { return row }
            var evidence = row.evidence
            evidence.protectedReason = nil
            var lifted = row.with(evidence: evidence, aiEvidence: row.aiEvidence)
            lifted.manualOnly = true
            lifted.reproved = true
            lifted.trusted = false
            return lifted
        }
    }
    /// No scan yet, the last one is older than the result lifetime, or it judged by ages Settings no longer hold.
    var isStale: Bool {
        scansDisk && (scannedAt.map { Date.now.timeIntervalSince($0) > CleanupCandidate.resultLifetime } ?? true || scannedAges != ages)
    }

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

    /// The expanded scan, for the dashboard's "프로젝트까지 검사" and `--scan-report` only — never the loop or the menu.
    /// Its rows stay until the next expanded scan; each carries its own scan time, which the executor ages like any row.
    func scanProjects() async {
        while isDeleting() {
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
        }
        guard scansDisk else { return }
        if let projectsTask { return await projectsTask.value }
        let task = Task { [self] in
            // Shown before the open-files snapshot the context takes, which takes seconds.
            scanning.formUnion(Area.expanded)
            await scanExpanded(context: await sources.context(ages))
            projectsTask = nil
        }
        projectsTask = task
        await task.value
    }

    private func scanAll() async {
        explorer.cancel()
        scanning.formUnion(Area.regular)
        let context = await sources.context(ages)
        await scanAreas(Area.regular, context: context)
        generation += 1
        // Settings changed while it read: its rows were judged by other ages, so the result stays stale and the
        // executor refuses its rows. A later scan, not this one, makes it current.
        guard context.ages == ages else {
            scannedAt = nil
            scannedAges = nil
            return
        }
        // The start, as on each row: the panel's "too old" and the executor's must agree.
        scannedAt = context.now
        scannedAges = context.ages
        startExploring()
    }

    /// Fills `areas` with what they hold now, each row stamped with the scan's start and ages.
    private func scanAreas(_ areas: [Area], context: ScanContext) async {
        let scan = sources.area
        await withTaskGroup(of: (Area, [CleanupCandidate]).self) { group in
            for area in areas {
                group.addTask(priority: .utility) { (area, scan(area, context)) }
            }
            for await (area, found) in group {
                candidates[area] = Self.stamped(found, context)
                scanning.remove(area)
            }
        }
    }

    /// Runtimes; then the walk, the build caches it found judged with the usual ones' borrowers, and the usual ones whose
    /// package checkouts only a re-proof can clear. Off the main actor in task-group children, as `scanAreas`.
    private func scanExpanded(context: ScanContext) async {
        enum Part: Sendable {
            case runtimes([CleanupCandidate])
            case jobs([CleanupCandidate])
            case projects([CleanupCandidate], ProjectDiscovery.Result, reproved: [CleanupCandidate])
        }
        let sources = sources
        await withTaskGroup(of: Part.self) { group in
            group.addTask(priority: .utility) { .runtimes(sources.area(.runtimes, context)) }
            group.addTask(priority: .utility) { .jobs(sources.area(.jobs, context)) }
            group.addTask(priority: .utility) {
                let discovery = sources.discover(context)
                let standard = XcodeCacheScanner.standardCaches(context.home)
                let lending = XcodeCacheScanner.lendingMap(caches: standard + discovery.derivedData, memory: context.borrowerMemory)
                let rows = ProjectOutputScanner.rows(discovery.derivedData, context: context, lending: lending, reprove: true)
                    + ProjectOutputScanner.artifactRows(discovery.artifacts, context: context)
                    + ProjectOutputScanner.nodeModulesRows(discovery.nodeModules, context: context)
                // Both sides resolved: listed folders end in "/", resolved ones do not.
                let key = { (url: URL) in PathKey.fold(PathGuard.realPath(url) ?? url.path(percentEncoded: false)) }
                let usual = Set(standard.map(key))
                let broken = lending.broken.filter { usual.contains(key(URL(fileURLWithPath: $0))) }
                return .projects(rows, discovery, reproved: broken.isEmpty ? [] : sources.reprove(context, broken))
            }
            for await part in group {
                switch part {
                case .runtimes(let rows):
                    candidates[.runtimes] = Self.stamped(rows, context)
                    scanning.remove(.runtimes)
                case .jobs(let rows):
                    candidates[.jobs] = Self.stamped(rows, context)
                    scanning.remove(.jobs)
                case .projects(let rows, let found, let reproved):
                    candidates[.projects] = Self.stamped(rows, context)
                    discovery = found
                    lifts = Self.lifts(reproved, usual: candidates[.xcode] ?? [])
                    scanning.remove(.projects)
                }
            }
        }
        // Settings changed while it read: as for the usual scan, its rows stay stale and its lifts are not applied.
        guard context.ages == ages else {
            projectsScannedAt = nil
            lifts = [:]
            return
        }
        projectsScannedAt = context.now
    }

    /// A re-proven row that a person may pick where the usual row with the same targets and last use is protected.
    nonisolated static func lifts(_ reproved: [CleanupCandidate], usual: [CleanupCandidate]) -> [String: ReproofLift] {
        var lifts: [String: ReproofLift] = [:]
        for row in reproved where row.isSelectable {
            guard let before = usual.first(where: { $0.id == row.id }), !before.isSelectable, before.targets == row.targets,
                  before.lastUsed == row.lastUsed, let reason = before.evidence.protectedReason else { continue }
            lifts[row.id] = ReproofLift(targets: before.targets, lastUsed: before.lastUsed, reason: reason)
        }
        return lifts
    }

    nonisolated static func stamped(_ rows: [CleanupCandidate], _ context: ScanContext) -> [CleanupCandidate] {
        rows.map { row in
            var row = row
            row.scannedAt = context.now
            row.ages = context.ages
            return row
        }.sorted(by: oldestFirst)
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
        if let projectsTask { await projectsTask.value }
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
        for id in ids { lifts.removeValue(forKey: id) }
    }

    nonisolated static func scan(_ area: Area, _ context: ScanContext) -> [CleanupCandidate] {
        switch area {
        case .xcode: XcodeCacheScanner.scan(context)
        case .appCaches: AppCacheScanner.scan(context)
        case .devices: DeveloperDeviceScanner.scan(context)
        case .general: GeneralCacheScanner.scan(context)
        case .runtimes: RuntimeScanner.scan(context)
        // Made by `scanProjects()` from its walk, which also feeds the borrower map; never scanned on its own.
        case .projects: []
        case .jobs: JobScratchScanner.scan(context)
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

    static func liveContext(ages: CleanupAges) async -> ScanContext {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home.appending(path: "Library/Caches").path(percentEncoded: false))) ?? []
        let installed = Set(names.filter { $0.contains(".") && NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil })
        let openFiles = await Task.detached(priority: .utility) { OpenFiles.capture() }.value
        return ScanContext(home: home, now: .now, openFiles: openFiles, runningBundleIDs: running, installedBundleIDs: installed, ages: ages,
                           borrowerMemory: .live())
    }
}
