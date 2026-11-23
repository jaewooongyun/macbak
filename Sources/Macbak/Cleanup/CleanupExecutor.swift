import AppKit

/// A local, append-only record of every clean-up: when it started, each item's path and outcome, and the free space
/// measured before and after. Names and paths only — never file contents, process arguments or `lsof` output.
struct CleanupAudit: Sendable {
    let url: URL
    /// Lines kept once the log grows past `trimAt`.
    var keep = 1_000
    var trimAt = 1_200

    static func live() -> CleanupAudit {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Macbak")
        return CleanupAudit(url: folder.appending(path: "cleanup-log.jsonl"))
    }

    func append(_ record: [String: String]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var line = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        line.append(0x0A)
        if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            try line.write(to: url, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        try trimIfNeeded()
    }

    private func trimIfNeeded() throws {
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count > trimAt else { return }
        try (lines.suffix(keep).joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

/// The only code that deletes. Every target is judged again right before it goes, and anything that fails a check is
/// skipped and reported rather than guessed at.
/// - Important: Checks per row, in order: it is ready or needs-a-choice; its scan is under `resultLifetime` old; no other
///   selected target overlaps it; its owners are idle (workspace files and running apps read again before every target,
///   AI tools per row and before a retry); then per target, an `lsof` snapshot under five seconds old shows nothing open
///   below it and the path guard passes (allowed root, no links on the way, not forbidden, no mount inside, same identity
///   — device, inode and own modification time — as when scanned). Listed files must also still have the modification
///   date they were listed with; a simulator must still be shut down.
/// - Note: It does not walk a folder again for recent changes: a workspace opened since the scan holds files open, which
///   the fresh snapshot catches; a change directly inside a folder moves its modification time; re-walking hundreds of
///   gigabytes would take minutes.
actor CleanupExecutor {
    struct Dependencies: Sendable {
        var allowedRoots: @Sendable () -> [URL]
        var forbidden: [URL]
        var openFiles: @Sendable () -> OpenFiles?
        var mounts: @Sendable () -> [String]?
        var simulators: @Sendable () -> [SimulatorList.Device]?
        var deleteSimulator: @Sendable (String) -> Bool
        var freeSpace: @Sendable () -> Int64?
        /// Bundle ids of running apps, or nil when they cannot be read.
        var runningBundleIDs: @Sendable () async -> Set<String>?
        /// Ids of running AI tools from a fresh, complete process sample, or nil.
        var runningTools: @Sendable () -> Set<String>?
        var audit: CleanupAudit
        /// Seconds an `lsof` snapshot may be reused.
        var snapshotLifetime: TimeInterval = 5
        /// Seconds after its scan a row may still be deleted.
        var resultLifetime: TimeInterval = CleanupCandidate.resultLifetime
        var retryDelay: Duration = .milliseconds(500)
        /// The clean-up ages Settings hold now; a row judged by other ages is refused, before every target and retry too.
        var currentAges: @Sendable () -> CleanupAges = { CleanupAges() }

        static func live() -> Dependencies {
            let home = FileManager.default.homeDirectoryForCurrentUser
            return Dependencies(
                allowedRoots: { CleanupRoots.all(home: home) + CleanupRoots.ruleRoots(home: home) },
                forbidden: CleanupRoots.forbidden(home: home),
                openFiles: { OpenFiles.capture() },
                mounts: { PathGuard.mountPoints() },
                simulators: { SimulatorList.read() },
                deleteSimulator: { udid in
                    Command.run("/usr/bin/xcrun", ["simctl", "delete", udid], timeout: .seconds(120))?.status == 0
                },
                // A fresh URL per reading: a URL keeps the resource values it read once, so re-reading `home` showed no change.
                freeSpace: { SystemReader.disk()?.available },
                runningBundleIDs: { await MainActor.run { Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)) } },
                runningTools: {
                    let sample = AIProcessSampler.sample(previous: [:], previousTime: 0)
                    return sample.complete ? sample.running : nil
                },
                audit: .live(),
                // Settings write every change at once, so the saved values are the current ones.
                currentAges: { CleanupAges(defaults: .standard) })
        }
    }

    enum Outcome: Sendable, Equatable {
        case deleted
        /// Some listed files went, others were skipped.
        case partial(deleted: Int, of: Int)
        case skipped(String)
        case failed(String)

        /// Only a full deletion: a partly deleted row stays listed, with its reason, until the next scan measures what is left.
        var succeeded: Bool {
            switch self {
            case .deleted: true
            case .partial, .skipped, .failed: false
            }
        }

        var reason: String? {
            switch self {
            case .deleted: nil
            case .partial(let deleted, let total): "\(total)개 중 \(deleted)개만 지움"
            case .skipped(let reason), .failed(let reason): reason
            }
        }
    }

    struct ItemResult: Sendable {
        let id: String
        let name: String
        let bytes: Int64
        let outcome: Outcome
    }

    struct Report: Sendable {
        var items: [ItemResult] = []
        var freeBefore: Int64?
        var freeAfter: Int64?
        /// Set when the run could not start at all.
        var refusal: String?

        var deleted: [ItemResult] { items.filter(\.outcome.succeeded) }
        /// Measured change in free space; nil when either reading failed. Other activity on the Mac shifts it too.
        var observedGain: Int64? {
            guard let freeBefore, let freeAfter else { return nil }
            return freeAfter - freeBefore
        }
    }

    private let dependencies: Dependencies
    private var running = false
    private var snapshot: (taken: Date, files: OpenFiles?)?

    init(dependencies: Dependencies = .live()) {
        self.dependencies = dependencies
    }

    /// Runs one clean-up. A second call while one runs is refused, so a double click cannot delete twice.
    /// - Parameters:
    ///   - latest: the row as the screens hold it now, asked just before each row is deleted. A rescan or the on-device
    ///     model may have held or protected a row since the list was handed over; that newer verdict wins.
    ///   - shallow: a run nobody chose row by row (the immediate clean-up, the loop): each row must still be in the
    ///     shallow set now, present with the same targets, or it is skipped.
    ///   - stop: asked before each row; once true, every row left is skipped. A row already started finishes: its
    ///     targets go together, since half a build cache breaks the next build.
    func run(_ candidates: [CleanupCandidate], latest: (@Sendable (String) async -> CleanupCandidate?)? = nil, shallow: Bool = false,
             stop: (@Sendable () async -> Bool)? = nil, progress: @Sendable (ItemResult) async -> Void) async -> Report {
        guard !running else { return Report(refusal: "이미 정리하는 중입니다.") }
        running = true
        // The open-files list holds tens of thousands of paths; it is let go with the run.
        defer {
            running = false
            snapshot = nil
        }

        var report = Report()
        do {
            try dependencies.audit.append(["event": "start", "time": Self.now(), "items": "\(candidates.count)"])
        } catch {
            return Report(refusal: "정리 기록을 남길 수 없어 시작하지 않았습니다: \(error.localizedDescription)")
        }
        report.freeBefore = dependencies.freeSpace()
        let overlapping = Self.overlapping(candidates)
        let mounts = dependencies.mounts()
        let roots = dependencies.allowedRoots()

        for candidate in candidates {
            let outcome: Outcome
            let stopped = await stop?() ?? false
            let current: CleanupCandidate? = if !stopped, let latest { await latest(candidate.id) } else { nil }
            if stopped {
                outcome = .skipped("중단해서 지우지 않았습니다")
            } else if let reason = await refusal(candidate, current: current, shallow: shallow, overlapping: overlapping,
                                                 roots: roots, mounts: mounts) {
                outcome = .skipped(reason)
            } else {
                outcome = await clean(candidate, roots: roots, mounts: mounts, shallow: shallow)
            }
            let result = ItemResult(id: candidate.id, name: candidate.name, bytes: candidate.bytes, outcome: outcome)
            report.items.append(result)
            try? dependencies.audit.append(["event": "item", "time": Self.now(), "name": candidate.name,
                                            "paths": candidate.targets.map { $0.path.path(percentEncoded: false) }.joined(separator: "\n"),
                                            "outcome": outcome.reason ?? "deleted", "bytes": "\(candidate.bytes)"])
            await progress(result)
        }
        report.freeAfter = dependencies.freeSpace()
        try? dependencies.audit.append(["event": "end", "time": Self.now(), "deleted": "\(report.deleted.count)",
                                        "freeBefore": report.freeBefore.map(String.init) ?? "?", "freeAfter": report.freeAfter.map(String.init) ?? "?"])
        return report
    }

    /// For a run nobody chose row by row: walks a whole target again just before deleting it, so a key, wallet or document
    /// put deep inside since the scan is seen — the target's own identity only changes with its direct entries. A walk
    /// that cannot finish refuses. Listed files (`removeFiles`) need none: only the files listed at the scan go.
    /// - Note: Seconds still pass between this walk and the deletion; a file written in them is not seen.
    static func deepRefusal(_ url: URL) -> String? {
        let facts = TreeWalk.inspect(url, budget: .seconds(60), alarm: CacheRules.isAlarmName, notice: CacheRules.blocksShallow)
        if let name = facts.alarm ?? facts.noticed { return "지우기 직전에 \(name)이(가) 안에서 보여 건너뜁니다" }
        if !facts.isComplete { return "지우기 직전에 다시 훑지 못해 건너뜁니다" }
        return nil
    }

    /// What a run would do with these rows now, deleting nothing: per row the reason it would be skipped, or nil when it
    /// would go. Each row stands for its own latest verdict. For `--scan-report`: a row shown as shallow that a run would
    /// skip is a promise the menu cannot keep, and this shows it before anyone clicks.
    /// - Note: Checks made only between targets or before a retry are not repeated; in a dry run nothing changes between them.
    func preflight(_ candidates: [CleanupCandidate], shallow: Bool) async -> [(id: String, refusal: String?)] {
        defer { snapshot = nil }
        let overlapping = Self.overlapping(candidates)
        let mounts = dependencies.mounts(), roots = dependencies.allowedRoots()
        var results: [(id: String, refusal: String?)] = []
        for candidate in candidates {
            results.append((candidate.id, await refusal(candidate, current: candidate, shallow: shallow, overlapping: overlapping,
                                                         roots: roots, mounts: mounts)))
        }
        return results
    }

    /// Every check made before the first target of a row is deleted, shared by `run` and `preflight` so that what the scan
    /// report says a run would do is what it does. All targets are checked before any is deleted, so a workspace's
    /// caches are not left half deleted by a check that could have failed up front — half a cache breaks the next build.
    private func refusal(_ candidate: CleanupCandidate, current: CleanupCandidate?, shallow: Bool, overlapping: Set<String>,
                         roots: [URL], mounts: [String]?) async -> String? {
        if !candidate.isSelectable { return "정리할 수 있는 상태가 아닙니다" }
        if shallow, !(current.map { $0.isShallow && $0.targets == candidate.targets } ?? false) { return "다시 검사한 결과 얕은 정리 대상이 아닙니다" }
        if let current, !current.isSelectable { return "다시 검사한 결과 지금은 고를 수 없습니다" }
        if candidate.scannedAt.map({ Date.now.timeIntervalSince($0) > dependencies.resultLifetime }) ?? true { return "검사한 지 오래돼 다시 검사해야 합니다" }
        if agesChanged(candidate) { return Self.agesRefusal }
        if overlapping.contains(candidate.id) { return "다른 항목과 경로가 겹칩니다" }
        guard let open = openFiles() else { return "열린 파일을 확인하지 못했습니다" }
        if let refusal = await ownerRefusal(candidate, open: open) { return refusal }
        for target in candidate.targets {
            switch target.action {
            case .removeItem:
                if open.anyOpen(under: target.path.path(percentEncoded: false)) { return "지금 쓰는 파일이 있습니다" }
                if let refusal = PathGuard.check(target.path, inside: target.root, identity: target.identity, allowedRoots: roots,
                                                 forbidden: dependencies.forbidden, mounts: mounts) {
                    return Self.describe(refusal)
                }
                if shallow, let refusal = Self.deepRefusal(target.path) { return refusal }
            case .deleteSimulator(let udid):
                // A clone can keep its apps and data in this simulator's folder, and that cannot be read while both are
                // shut down; only a person who saw the list deletes one.
                if shallow { return "시뮬레이터는 목록을 보고 골라야 지웁니다" }
                guard let device = dependencies.simulators()?.first(where: { $0.udid == udid }) else { return "시뮬레이터 목록을 읽지 못했습니다" }
                guard device.state == "Shutdown" else { return "시뮬레이터가 켜져 있습니다" }
                if open.anyOpen(under: device.dataPath) { return "지금 쓰는 파일이 있습니다" }
            case .removeFiles:
                break
            }
        }
        return nil
    }

    /// Deletes a row that passed `refusal`. If an owner starts part way, the row stops there instead: a running app or
    /// open workspace outweighs a whole group. Listed files are judged one by one.
    private func clean(_ candidate: CleanupCandidate, roots: [URL], mounts: [String]?, shallow: Bool) async -> Outcome {
        // Counted up front: a row stopped part way must not read as fully deleted.
        let total = candidate.targets.reduce(0) { count, target in
            if case .removeFiles(let files) = target.action { count + files.count } else { count + 1 }
        }
        var removed = 0, firstError: String?
        for (index, target) in candidate.targets.enumerated() {
            if agesChanged(candidate) { firstError = firstError ?? Self.agesRefusal; break }
            let isFolder = if case .removeItem = target.action { true } else { false }
            // Apps and the workspace are asked again before every further target; an AI tool sample costs too much to repeat.
            // A folder asks them below instead, after its walk.
            if index > 0, !isFolder {
                guard let open = openFiles() else { firstError = firstError ?? "열린 파일을 확인하지 못했습니다"; break }
                if let refusal = await ownerRefusal(candidate, open: open, tools: false) { firstError = firstError ?? refusal; break }
            }
            // Each folder is checked again right before it goes, not only in the row's up-front check: with several targets,
            // that check of a later one can be minutes old by then (earlier deletions, deep walks). The slow questions come
            // first: a run nobody chose walks the folder again (up to a minute), then the owners are asked (an app started
            // during the walk; AI tools too after a walk). The open files (a snapshot started under five seconds ago) and
            // the path guard come last, nothing slow between them and the deletion.
            if isFolder {
                if shallow, let refusal = Self.deepRefusal(target.path) {
                    firstError = firstError ?? refusal
                    break
                }
                if index > 0 || shallow {
                    guard let before = openFiles() else { firstError = firstError ?? "열린 파일을 확인하지 못했습니다"; break }
                    if let refusal = await ownerRefusal(candidate, open: before, tools: shallow) { firstError = firstError ?? refusal; break }
                }
                guard let open = openFiles() else { firstError = firstError ?? "열린 파일을 확인하지 못했습니다"; break }
                if open.anyOpen(under: target.path.path(percentEncoded: false)) { firstError = firstError ?? "지금 쓰는 파일이 있습니다"; break }
                if Self.workspaceOpen(candidate, open) { firstError = firstError ?? "작업 공간에서 쓰는 파일이 있습니다"; break }
                if let refusal = PathGuard.check(target.path, inside: target.root, identity: target.identity, allowedRoots: roots,
                                                 forbidden: dependencies.forbidden, mounts: mounts) {
                    firstError = firstError ?? Self.describe(refusal)
                    break
                }
                // Settings changed during the slow checks leave the row judged by old ages.
                if agesChanged(candidate) { firstError = firstError ?? Self.agesRefusal; break }
            }
            switch target.action {
            case .removeItem:
                // And again before a retry, in the same order: the slow questions first (the walk, which apps and tools
                // run, which can wait on the main actor), then open files from a snapshot aged at that moment, and the guard.
                let check = { () async -> Bool in
                    if self.agesChanged(candidate) { return false }
                    if shallow, Self.deepRefusal(target.path) != nil { return false }
                    guard let before = self.openFiles(fresh: true), await self.ownerRefusal(candidate, open: before) == nil,
                          let open = self.openFiles(), !open.anyOpen(under: target.path.path(percentEncoded: false)),
                          !Self.workspaceOpen(candidate, open) else { return false }
                    return PathGuard.check(target.path, inside: target.root, identity: target.identity, allowedRoots: roots,
                                           forbidden: self.dependencies.forbidden, mounts: mounts) == nil
                        && !self.agesChanged(candidate)
                }
                if let error = await remove(target.path, recheck: check) { firstError = firstError ?? error } else { removed += 1 }
            case .deleteSimulator(let udid):
                if dependencies.deleteSimulator(udid) { removed += 1 } else { firstError = firstError ?? "simctl delete 실패" }
            case .removeFiles(let files):
                for file in files {
                    let url = URL(fileURLWithPath: file.path)
                    guard let current = openFiles(), !current.anyOpen(under: file.path),
                          PathGuard.check(url, inside: target.root, identity: file.identity, allowedRoots: roots,
                                          forbidden: dependencies.forbidden, mounts: mounts) == nil,
                          (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate == file.modified
                    else { continue }
                    let check = { () async -> Bool in
                        guard !self.agesChanged(candidate), let before = self.openFiles(fresh: true),
                              await self.ownerRefusal(candidate, open: before) == nil,
                              let open = self.openFiles(), !open.anyOpen(under: file.path), !Self.workspaceOpen(candidate, open) else { return false }
                        return PathGuard.check(url, inside: target.root, identity: file.identity, allowedRoots: roots,
                                               forbidden: self.dependencies.forbidden, mounts: mounts) == nil
                            && (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate == file.modified
                    }
                    if let error = await remove(url, recheck: check) { firstError = firstError ?? error } else { removed += 1 }
                }
            }
        }
        if removed == total { return .deleted }
        if removed > 0 { return .partial(deleted: removed, of: total) }
        return firstError.map(Outcome.failed) ?? .skipped("목록을 만든 뒤 바뀌어서 지우지 않았습니다")
    }

    /// Why the row's owners now forbid deleting it, or nil when all are idle: a file open in the workspace folder, or an
    /// owning app or AI tool running. The scan relied on them, so they are asked again; apps and tools are read fresh on
    /// every call, so one started mid-run still protects its cache.
    /// - Parameter tools: false skips the AI tool sample, which costs about a tenth of a second; it is taken per row and
    ///   before a retry, while apps and the workspace are also asked between the targets of a row.
    private func ownerRefusal(_ candidate: CleanupCandidate, open: OpenFiles, tools: Bool = true) async -> String? {
        if Self.workspaceOpen(candidate, open) { return "작업 공간에서 쓰는 파일이 있습니다" }
        if !candidate.guards.bundleIDs.isEmpty {
            guard let running = await dependencies.runningBundleIDs() else { return "실행 중인 앱을 확인하지 못했습니다" }
            let folded = Set(running.map(PathKey.fold))
            if candidate.guards.bundleIDs.contains(where: { folded.contains(PathKey.fold($0)) }) { return "앱이 실행 중입니다" }
        }
        if tools, !candidate.guards.toolIDs.isEmpty {
            guard let running = dependencies.runningTools() else { return "AI 도구 실행 여부를 확인하지 못했습니다" }
            if candidate.guards.toolIDs.contains(where: running.contains) { return "AI 도구가 실행 중입니다" }
        }
        return nil
    }

    static let agesRefusal = "정리 기준이 바뀌어 다시 검사해야 합니다"

    /// Whether Settings now hold other clean-up ages than the scan judged the row by.
    private func agesChanged(_ candidate: CleanupCandidate) -> Bool { candidate.ages != dependencies.currentAges() }

    /// Whether a file is open in one of the row's watched folders (its workspace's own folder).
    private static func workspaceOpen(_ candidate: CleanupCandidate, _ open: OpenFiles) -> Bool {
        candidate.guards.watchPaths.contains { open.anyOpen(under: $0.path(percentEncoded: false)) }
    }

    /// Deletes, then once more after a short wait (Xcode may be writing into the folder) — but only if `recheck` still
    /// passes, since the item may have been replaced, or its owner started, while waiting. The error text if it is not deleted.
    private func remove(_ url: URL, recheck: () async -> Bool) async -> String? {
        do {
            try FileManager.default.removeItem(at: url)
            return nil
        } catch {
            try? await Task.sleep(for: dependencies.retryDelay)
            guard await recheck() else { return "다시 시도하기 전에 바뀌어서 그만둠" }
            do {
                try FileManager.default.removeItem(at: url)
                return nil
            } catch {
                return error.localizedDescription
            }
        }
    }

    /// An open-file snapshot under `snapshotLifetime` old, aged from when `lsof` started; nil when none can be had.
    /// - Parameter fresh: capture a new one even if a recent one exists (before a retry).
    /// - Important: A capture that itself took longer than the lifetime is refused, not used: what it says about the first
    ///   processes it read is already too old to delete by. `lsof` usually takes a second or two; the limit is 15 s.
    private func openFiles(fresh: Bool = false) -> OpenFiles? {
        if !fresh, let snapshot, Date.now.timeIntervalSince(snapshot.taken) < dependencies.snapshotLifetime { return snapshot.files }
        let started = Date.now
        let files = dependencies.openFiles()
        guard Date.now.timeIntervalSince(started) < dependencies.snapshotLifetime else {
            snapshot = nil
            return nil
        }
        snapshot = (started, files)
        return files
    }

    /// Ids of candidates with a target that is the same as, inside, or around another selected target.
    static func overlapping(_ candidates: [CleanupCandidate]) -> Set<String> {
        let entries = candidates.flatMap { candidate in
            candidate.targets.map { (candidate.id, PathGuard.realPath($0.path).map(PathKey.fold) ?? PathKey.fold($0.path.path(percentEncoded: false))) }
        }
        var clashing: Set<String> = []
        for (i, a) in entries.enumerated() {
            for b in entries[(i + 1)...] where a.0 != b.0 {
                if a.1 == b.1 || a.1.hasPrefix(b.1 + "/") || b.1.hasPrefix(a.1 + "/") {
                    clashing.insert(a.0)
                    clashing.insert(b.0)
                }
            }
        }
        return clashing
    }

    static func describe(_ refusal: PathGuard.Refusal) -> String {
        switch refusal {
        case .rootNotAllowed: "허용된 위치가 아닙니다"
        case .isRoot: "정리 위치 자체는 지우지 않습니다"
        case .notInsideRoot: "정리 위치 밖입니다"
        case .symbolicLink(let part): "경로에 링크가 있습니다(\(part))"
        case .forbidden: "지우지 않도록 정한 위치입니다"
        case .unreadable(let part): "확인할 수 없습니다(\(part))"
        case .containsMount: "다른 볼륨이 연결돼 있습니다"
        case .identityChanged: "검사 뒤에 바뀌었습니다"
        case .rootIsLinked: "정리 위치가 링크입니다"
        }
    }

    private static func now() -> String { ISO8601DateFormatter().string(from: .now) }
}

extension CleanupExecutor.Report {
    /// "실제로 늘어난 공간 41.2 GB (전후 측정)" — the measured change, which other activity on the Mac can shift.
    var gainText: String {
        guard let gain = observedGain else { return "늘어난 공간을 재지 못했습니다" }
        return gain > 0 ? "실제로 늘어난 공간 \(gain.diskText) (전후 측정)" : "여유 공간 변화가 측정되지 않았습니다"
    }
}
