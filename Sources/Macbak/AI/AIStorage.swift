import Foundation
import Observation

enum AIStorageRules {
    /// - Parameter staleAfter: the finished-job age picked in Settings.
    /// - Returns: nil when the job should not be listed at all: it finished recently, so its results may still be wanted.
    static func jobScratchEvidence(state: String?, store: JobStore, newestFileAge: TimeInterval,
                                   staleAfter: TimeInterval = CleanupAges().seconds(.aiJobScratch)) -> Evidence? {
        if store.isAlive(state) { return Evidence(verified: true, inUse: true, regenerable: false) }
        guard let state, store.finished.contains(state) else { return Evidence() }
        guard newestFileAge >= staleAfter else { return nil }
        return Evidence(verified: true, inUse: false, regenerable: false, userData: true)
    }

    /// `nil` means "could not tell", which keeps the item protected.
    static func inUse(_ running: Set<String>?, any tools: [String]) -> Bool? {
        running.map { running in tools.contains { running.contains($0) } }
    }

    /// In use when an owning tool runs or a process has a file open below the folders. Either probe missing is "could not
    /// tell", unless the other already says "in use".
    static func inUse(_ running: Set<String>?, any tools: [String], openFiles: OpenFiles?, folders: [String]) -> Bool? {
        if inUse(running, any: tools) == true { return true }
        if let openFiles, folders.contains(where: openFiles.anyOpen(under:)) { return true }
        guard running != nil, openFiles != nil else { return nil }
        return false
    }

    static func evidence(for kind: StorageArea.Kind, inUse: Bool?) -> Evidence {
        switch kind {
        case .cache: Evidence(verified: true, inUse: inUse, regenerable: true)
        case .download: Evidence(verified: true, inUse: inUse, regenerable: true, downloadCost: true)
        case .stale: Evidence(verified: true, inUse: inUse, regenerable: true)
        case .shared: Evidence(verified: true, inUse: nil, regenerable: true, downloadCost: true)
        }
    }

    static func explanation(for kind: StorageArea.Kind) -> String {
        switch kind {
        case .cache: "앱이 다시 만듦"
        case .download: "다시 쓰면 내려받음"
        case .stale(let days): "\(Int(days))일 넘게 지난 파일만"
        case .shared: "열린 파일 검사가 아직 없어 사용 여부를 모름"
        }
    }
}

struct FolderSize: Sendable {
    var bytes: Int64 = 0
    var files = 0
    var newest: Date?
    /// The time budget ran out, so `bytes` is a lower bound.
    var partial = false

    mutating func add(_ other: FolderSize) {
        bytes += other.bytes
        files += other.files
        partial = partial || other.partial
        if let date = other.newest, date > (newest ?? .distantPast) { newest = date }
    }
}

enum FolderScanner {
    /// Allocated size of regular files under `url`, optionally only those last modified before `cutoff`.
    /// Symbolic links are not followed. Only names, sizes and dates are read.
    static func size(of url: URL, budget: TimeInterval = 6, modifiedBefore cutoff: Date? = nil) -> FolderSize {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .contentModificationDateKey]
        var result = FolderSize()
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, errorHandler: { _, _ in true }) else { return result }
        let deadline = Date.now.addingTimeInterval(budget)
        for case let file as URL in walker {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let modified = values.contentModificationDate
            if let cutoff, let modified, modified >= cutoff { continue }
            result.bytes += Int64(values.totalFileAllocatedSize ?? 0)
            result.files += 1
            if let modified, modified > (result.newest ?? .distantPast) { result.newest = modified }
            if result.files % 512 == 0, Date.now > deadline {
                result.partial = true
                break
            }
        }
        return result
    }

    static func size(of paths: [StoragePath], home: URL, budget: TimeInterval = 6, modifiedBefore cutoff: Date? = nil) -> FolderSize {
        paths.reduce(into: FolderSize()) { total, path in total.add(size(of: path.url(home: home), budget: budget, modifiedBefore: cutoff)) }
    }
}

struct AIStorageReport: Sendable {
    struct Total: Identifiable, Sendable {
        let id: String
        let name: String
        /// nil for caches no single tool owns.
        let vendor: AIVendor?
        let bytes: Int64
        let partial: Bool
    }

    var totals: [Total]
    var candidates: [CleanupCandidate]
    var scannedAt: Date
    var duration: TimeInterval
    /// The clean-up ages the scan judged by.
    var ages = CleanupAges()
}

enum AIStorageScanner {
    /// - Parameters:
    ///   - running: ids of tools seen running, or nil without a complete, fresh process sample (then nothing counts as unused).
    ///   - openFiles: an `lsof` snapshot, or nil when it failed (then nothing counts as unused).
    ///   - ages: the clean-up ages picked in Settings when the scan started.
    static func scan(running: Set<String>?, openFiles: OpenFiles?, catalog: [AITool] = AITool.catalog,
                     shared: [StorageArea] = AITool.sharedCaches,
                     home: URL = FileManager.default.homeDirectoryForCurrentUser, ages: CleanupAges = CleanupAges()) -> AIStorageReport {
        let started = Date.now
        var candidates: [CleanupCandidate] = []
        func add(_ candidate: CleanupCandidate?) { if let candidate, candidate.bytes > 0 { candidates.append(candidate) } }

        for tool in catalog {
            for area in tool.cleanable {
                add(candidate(for: area, id: "\(tool.id).\(area.id)", owner: tool.name, home: home, now: started,
                              running: running, tools: [tool.id] + area.sharedWith, openFiles: openFiles))
            }
            if let jobs = tool.jobs { jobCandidates(tool: tool, store: jobs, home: home, now: started, ages: ages).forEach(add) }
            if let log = tool.sessions { add(oldLogCandidate(tool: tool, log: log, home: home, now: started, ages: ages)) }
        }
        for area in shared {
            add(candidate(for: area, id: "shared.\(area.id)", owner: nil, home: home, now: started,
                          running: nil, tools: [], openFiles: openFiles))
        }

        var totals = catalog.filter { !$0.footprint.isEmpty }.map { tool in
            let size = FolderScanner.size(of: tool.footprint, home: home, budget: 4)
            return AIStorageReport.Total(id: tool.id, name: tool.name, vendor: tool.vendor, bytes: size.bytes, partial: size.partial)
        }
        let sharedSize = FolderScanner.size(of: shared.flatMap(\.paths), home: home, budget: 4)
        totals.append(AIStorageReport.Total(id: "shared", name: "공용 캐시", vendor: nil, bytes: sharedSize.bytes, partial: sharedSize.partial))
        totals = totals.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }
        for index in candidates.indices {
            candidates[index].scannedAt = started
            candidates[index].ages = ages
        }
        // The start, as on each row: the panel's "too old" and the executor's must agree.
        return AIStorageReport(totals: totals, candidates: candidates, scannedAt: started, duration: Date.now.timeIntervalSince(started), ages: ages)
    }

    /// One row per area. A cache area offers each item inside its folders (the folders stay for the tool to refill); a
    /// stale area offers exactly the old files listed now, minus any a process has open.
    /// - Important: Facts come from `TreeWalk`, so an unreadable item or a budget hit makes the row "could not tell".
    private static func candidate(for area: StorageArea, id: String, owner: String?, home: URL, now: Date,
                                  running: Set<String>?, tools: [String], openFiles: OpenFiles?) -> CleanupCandidate {
        var cutoff: Date?
        if case .stale(let days) = area.kind { cutoff = now.addingTimeInterval(-days * 86_400) }
        var bytes: Int64 = 0
        var complete = true
        var targets: [CleanupTarget] = []
        var folders: [String] = []
        // A key, wallet or disk image anywhere inside keeps the row; a document keeps it out of the shallow clean-up.
        var alarm: String?, noticed: String?

        for path in area.paths {
            // Built from the resolved path, as the path guard requires. A folder that does not exist has nothing to clean,
            // and one reached through a link is skipped: its contents are not this tool's cache.
            let written = path.url(home: home)
            guard let rootPath = PathGuard.realPath(written), PathGuard.isTrusted(written, resolvedTo: rootPath) else { continue }
            let root = URL(fileURLWithPath: rootPath, isDirectory: true)
            folders.append(rootPath)
            if let cutoff {
                let facts = TreeWalk.inspect(root, budget: .seconds(20), olderThan: cutoff, collect: true,
                                             alarm: CacheRules.isAlarmName, notice: CacheRules.blocksShallow)
                complete = complete && facts.isComplete
                alarm = alarm ?? facts.alarm
                noticed = noticed ?? facts.noticed
                let files = facts.listed.filter { openFiles?.anyOpen(under: $0.path) != true }
                bytes += files.reduce(0) { $0 + $1.bytes }
                if !files.isEmpty {
                    targets.append(CleanupTarget(path: root, root: root, identity: FileIdentity.of(rootPath), action: .removeFiles(files)))
                }
            } else {
                guard let items = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
                    complete = false
                    continue
                }
                for item in items {
                    let facts = TreeWalk.inspect(item, budget: .seconds(20), alarm: CacheRules.isAlarmName, notice: CacheRules.blocksShallow)
                    complete = complete && facts.isComplete
                    alarm = alarm ?? facts.alarm
                    noticed = noticed ?? facts.noticed
                    bytes += facts.bytes
                    let itemPath = item.path(percentEncoded: false)
                    targets.append(CleanupTarget(path: item, root: root, identity: FileIdentity.of(itemPath), action: .removeItem))
                }
            }
        }

        let detail = [owner, area.paths.map(\.display).joined(separator: ", "), area.note ?? AIStorageRules.explanation(for: area.kind)]
            .compactMap(\.self).joined(separator: " · ")
        var inUse = AIStorageRules.inUse(running, any: tools, openFiles: openFiles, folders: folders)
        if case .stale = area.kind {
            // Only old files go, and open ones were left out above; the owner running does not matter.
            inUse = openFiles == nil ? nil : false
        }
        if case .shared = area.kind { inUse = nil }
        var evidence = AIStorageRules.evidence(for: area.kind, inUse: inUse)
        if !complete { evidence.verified = nil }
        if let alarm { evidence.protectedReason = CacheRules.alarmReason(alarm) }
        var guards = CleanupGuards()
        if case .stale = area.kind {} else { guards.toolIDs = tools }
        var row = CleanupCandidate(id: id, name: area.name, detail: detail, symbol: area.symbol, bytes: bytes,
                                   evidence: evidence, lowerBound: !complete, targets: targets, guards: guards)
        // The catalog vouches that a tool's own cache and its old logs come back by themselves.
        switch area.kind {
        case .cache, .stale: row.trusted = noticed == nil
        case .download, .shared: break
        }
        // uv asks to be cleaned with its own command; show it on the row (the row itself stays as the rules above set it).
        if area.paths.contains(where: { if case .home(let path) = $0 { GeneralCacheScanner.commandOnly.contains(path) } else { false } }) {
            row.toolCommand = CacheRules.devRow(".cache/uv")?.command
        }
        return row
    }

    /// Job scratch files grouped by what each job's state allows.
    private static func jobCandidates(tool: AITool, store: JobStore, home: URL, now: Date, ages: CleanupAges) -> [CleanupCandidate] {
        var finished = FolderSize(), running = FolderSize(), unknown = FolderSize()
        var finishedCount = 0, recentCount = 0, runningCount = 0, unknownCount = 0
        for job in store.jobFolders(home: home) {
            let state = store.state(of: job)
            let scratch = FolderScanner.size(of: job.appending(path: store.scratch), budget: 2)
            let age = scratch.newest.map { now.timeIntervalSince($0) } ?? .infinity
            guard let evidence = AIStorageRules.jobScratchEvidence(state: state, store: store, newestFileAge: age,
                                                                   staleAfter: ages.seconds(.aiJobScratch)) else {
                recentCount += 1
                continue
            }
            switch evaluate(evidence).status {
            case .review: finished.add(scratch); finishedCount += 1
            case .protected where store.isAlive(state): running.add(scratch); runningCount += 1
            default: unknown.add(scratch); unknownCount += 1
            }
        }
        let days = ages.aiJobScratch
        return [
            CleanupCandidate(id: "\(tool.id).jobs-finished", name: "끝난 \(tool.name) 작업의 임시 파일",
                             detail: "작업 \(finishedCount)개 · \(days)일 넘게 바뀌지 않음 · 최근에 끝난 \(recentCount)개는 제외 · 디스크 화면에서 골라 지울 수 있음", symbol: "doc.on.doc",
                             bytes: finished.bytes, evidence: Evidence(verified: true, inUse: false, regenerable: false, userData: true), lowerBound: finished.partial),
            CleanupCandidate(id: "\(tool.id).jobs-running", name: "진행 중인 \(tool.name) 작업", detail: "작업 \(runningCount)개 · 실행 중이거나 입력을 기다리는 중이라 건드리지 않음",
                             symbol: "gearshape.2", bytes: running.bytes, evidence: Evidence(verified: true, inUse: true, regenerable: false), lowerBound: running.partial),
            CleanupCandidate(id: "\(tool.id).jobs-unknown", name: "상태를 읽지 못한 \(tool.name) 작업", detail: "작업 \(unknownCount)개",
                             symbol: "questionmark.folder", bytes: unknown.bytes, evidence: Evidence(), lowerBound: unknown.partial),
        ]
    }

    private static func oldLogCandidate(tool: AITool, log: SessionLog, home: URL, now: Date, ages: CleanupAges) -> CleanupCandidate {
        let cutoff = now.addingTimeInterval(-ages.seconds(.aiChatLogs))
        var bytes: Int64 = 0, files = 0
        log.forEachLog(home: home, keys: [.contentModificationDateKey, .totalFileAllocatedSizeKey]) { _, _, _, values in
            guard let modified = values.contentModificationDate, modified < cutoff else { return }
            bytes += Int64(values.totalFileAllocatedSize ?? 0)
            files += 1
        }
        return CleanupCandidate(id: "\(tool.id).old-logs", name: "\(ages.aiChatLogs)일 넘은 \(tool.name) 대화 기록",
                                detail: "파일 \(files)개 · ~/\(log.root) · 대화 기록이라 표시만", symbol: "text.bubble", bytes: bytes,
                                evidence: Evidence(verified: true, inUse: false, regenerable: false, userData: true))
    }
}

@MainActor
@Observable
final class AIStorage {
    private(set) var report: AIStorageReport?
    private(set) var scanning = false
    /// The scan in progress, which later callers wait for.
    @ObservationIgnored private var current: Task<Void, Never>?
    /// Whether a clean-up is deleting. A scan does not start until it ends, so it never measures folders half deleted.
    @ObservationIgnored var isDeleting: @MainActor () -> Bool = { false }
    /// Rows deleted while a scan was reading. A clean-up does not wait for this scan (it takes most of a minute), so the
    /// scan may have read them before they went; they are dropped from its report when it lands, not put back.
    @ObservationIgnored private var forgottenWhileScanning: Set<String> = []
    /// The disk reading itself, off the main actor; replaceable so a test can hold a scan open.
    @ObservationIgnored var read: @Sendable (Set<String>?, CleanupAges) -> AIStorageReport = {
        AIStorageScanner.scan(running: $0, openFiles: OpenFiles.capture(), ages: $1)
    }
    /// The ages picked in Settings; nil keeps the defaults.
    @ObservationIgnored let settings: CleanupSettings?

    init(settings: CleanupSettings? = nil) {
        self.settings = settings
    }

    var ages: CleanupAges { settings?.ages ?? CleanupAges() }

    /// Drops rows a clean-up deleted, so lists are right without a rescan.
    func forget(_ ids: Set<String>) {
        report?.candidates.removeAll { ids.contains($0.id) }
        if current != nil { forgottenWhileScanning.formUnion(ids) }
    }

    /// No report yet, the last scan is older than ten minutes, or it judged by ages Settings no longer hold.
    var isStale: Bool {
        report.map { Date.now.timeIntervalSince($0.scannedAt) > CleanupCandidate.resultLifetime || $0.ages != ages } ?? true
    }

    /// Scans off the main actor. Running tools come from the monitor's latest sample; before the first sample nothing counts as unused.
    /// A call while a scan runs waits for that scan rather than returning at once, so the caller never reads the old report.
    func scan(using monitor: AIMonitor) async {
        while isDeleting() {
            // A cancelled sleep throws at once; ignoring it would spin the main actor. The caller no longer wants the scan.
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
        }
        if let current { return await current.value }
        let task = Task { [self] in
            scanning = true
            let running = monitor.runningToolIDs
            let read = read
            let ages = ages
            var fresh = await Task.detached(priority: .utility) { read(running, ages) }.value
            fresh.candidates.removeAll { forgottenWhileScanning.contains($0.id) }
            forgottenWhileScanning = []
            // Settings changed while it read: its rows were judged by other ages, so it is not kept.
            report = self.ages == ages ? fresh : nil
            scanning = false
            current = nil
        }
        current = task
        await task.value
    }
}
