import Foundation

/// `--scan-report`: scans the real disk with the disk screen's two scans, the usual one and then the expanded one (the
/// screen runs them at once), and prints every candidate with its verdict, then
/// exits. Read-only — it never deletes — so a scanner change can be checked against the actual Mac before any clean-up.
@MainActor
enum ScanReport {
    static func run() {
        // The ages picked in Settings, read only.
        let settings = CleanupSettings()
        let coordinator = CleanupCoordinator(settings: settings)
        // AI tool caches too, the way the app scans them: AI processes first, so unused caches can be told.
        let ai = AIMonitor(isWindowShown: { true })
        let storage = AIStorage(settings: settings)
        let started = Date.now
        var finished = false
        Task {
            await coordinator.scan()
            await coordinator.scanProjects()
            await ai.wake()
            await storage.scan(using: ai)
            finished = true
        }
        while !finished, Date.now.timeIntervalSince(started) < 900 { RunLoop.main.run(until: .now.addingTimeInterval(0.5)) }
        print(String(format: "scan: %.1fs%@", Date.now.timeIntervalSince(started), finished ? "" : " (timed out)"))
        print("environment: " + (DiskScreen.environmentText(coordinator.environment) ?? "(찾은 작업 없음)"))

        // The on-device model looks after the scan; wait for it so its findings are part of the report.
        let exploreStarted = Date.now
        while case .exploring = coordinator.explorer.phase, Date.now.timeIntervalSince(exploreStarted) < 600 {
            RunLoop.main.run(until: .now.addingTimeInterval(0.5))
        }
        print(String(format: "explorer: %@ in %.1fs", String(describing: coordinator.explorer.phase), Date.now.timeIntervalSince(exploreStarted)))
        for row in coordinator.all where row.exploreInput != nil {
            let role = row.exploreInput?.role == .veto ? "veto" : "offer"
            print("  AI \(role)\t\(row.verdict.status.title)\t\(row.bytes.diskText)\t\(row.name)\t\(row.verdict.reason)\t\(row.aiEvidence ?? "")")
        }

        // The menu bar's immediate clean-up, from the disk areas and the AI tool caches together.
        let rows = coordinator.all + (storage.report?.candidates ?? [])
        let shallow = rows.filter(\.isShallow)
        print("\nAI storage rows: \(storage.report?.candidates.count ?? -1)")
        print("shallow: \(shallow.count) · \(shallow.reduce(0) { $0 + $1.bytes }.diskText)")
        for row in shallow { print("  \(row.bytes.diskText)\t\(row.id)") }
        let untrusted = rows.filter { $0.isPreselected && !$0.trusted }
        print("ticked in the dashboard only: \(untrusted.count) · \(untrusted.reduce(0) { $0 + $1.bytes }.diskText)")

        // The memory screen's reading, twice, ten seconds apart as the screen refreshes; counts only.
        let processes = processes(SystemMonitor.ProcessSources(), apps: OrphanProcesses.runningApps(),
                                  idleAge: settings.ages.seconds(.aiSessionIdle)) { RunLoop.main.run(until: .now.addingTimeInterval(10)) }
        print("")
        for line in lines(Summary(runtimes: coordinator.rows(in: .runtimes), projects: coordinator.rows(in: .projects), jobs: coordinator.rows(in: .jobs),
                                  discovery: coordinator.discovery, standardCaches: XcodeCacheScanner.standardCaches(FileManager.default.homeDirectoryForCurrentUser).count,
                                  memory: BorrowerMemory.live().load(), lifts: coordinator.lifts.count, processes: processes)) {
            print(line)
        }
        for area in CleanupCoordinator.Area.allCases {
            let found = coordinator.rows(in: area)
            print("\n== \(area.title): \(found.count)")
            for status in CleanupStatus.allCases {
                let rows = found.filter { $0.verdict.status == status }
                guard !rows.isEmpty else { continue }
                print("  [\(status.title)] \(rows.count)개 · \(rows.reduce(0) { $0 + $1.bytes }.diskText)")
                for row in rows { print(rowLine(row)) }
            }
        }
        let forbidden = CleanupRoots.forbidden(home: FileManager.default.homeDirectoryForCurrentUser).map { PathKey.fold($0.path(percentEncoded: false)) }
        let leaks = rows.flatMap(\.targets).filter { target in
            let path = PathKey.fold(target.path.path(percentEncoded: false))
            return forbidden.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
        // Must be 0 among rows a person can tick. A protected row may still list them (the shared uv cache does); it can
        // never be ticked, and the path guard refuses them again at deletion.
        let selectableLeaks = rows.filter(\.isSelectable).flatMap(\.targets).filter { leaks.contains($0) }
        print("\nforbidden paths among targets of selectable rows: \(selectableLeaks.count)")
        for row in rows where !row.isSelectable && row.targets.contains(where: { leaks.contains($0) }) {
            print("  (protected, never selectable) \(row.id): \(row.targets.filter { leaks.contains($0) }.count)")
        }
        // A row a person can tick whose deletion root the executor would refuse is a broken link between screen and
        // clean-up. Computed the way the executor computes its allowed roots.
        let home = FileManager.default.homeDirectoryForCurrentUser
        let allowed = Set((CleanupRoots.all(home: home) + CleanupRoots.ruleRoots(home: home)).compactMap(PathGuard.realPath))
        // Simulators and runtimes are deleted with `simctl`, which the path guard never sees.
        let unreachable = rows.filter(\.isSelectable).filter { row in
            row.targets.contains { target in
                switch target.action {
                case .deleteSimulator, .deleteRuntime: return false
                case .removeItem, .removeFiles: break
                }
                // A granted folder has no root: the executor checks exactly it, below the home.
                if let grant = target.grant {
                    return PathGuard.checkExact(target.path, grant: grant.path, identity: target.identity, home: home,
                                                forbidden: CleanupRoots.forbidden(home: home), mounts: PathGuard.mountPoints()) != nil
                }
                return PathGuard.realPath(target.root).map { !allowed.contains($0) } ?? true
            }
        }
        print("selectable rows whose root the executor would refuse: \(unreachable.count)")
        for row in unreachable { print("  \(row.id)\t\(row.targets.first.map { $0.root.path(percentEncoded: false) } ?? "")") }

        // The executor's own checks on the shallow set, deleting nothing: a row the menu offers that a run would skip
        // is a promise the menu cannot keep (on 2026-11-04 the menu offered 101 GB and a run skipped 80 GB of it).
        let executor = CleanupExecutor()
        var verdicts: [(id: String, refusal: String?)]?
        Task { verdicts = await executor.preflight(shallow, shallow: true) }
        while verdicts == nil { RunLoop.main.run(until: .now.addingTimeInterval(0.2)) }
        let skipped = (verdicts ?? []).filter { $0.refusal != nil }
        print("shallow rows a run would skip now: \(skipped.count)")
        for row in skipped { print("  \(row.id)\t\(row.refusal ?? "")") }
        exit(0)
    }

    /// What the expanded scan and the memory side found, for the report's summary.
    struct Summary {
        struct Processes: Equatable {
            var helpersSummed: Bool
            var orphans: Int
            /// nil when the sessions folder could not be read.
            var idleSessions: Int?
            /// Virtual machines and emulators running.
            var machines = 0
        }

        var runtimes: [CleanupCandidate]
        var projects: [CleanupCandidate]
        var jobs: [CleanupCandidate]
        var discovery: ProjectDiscovery.Result?
        /// The usual build cache folders the lending map read besides the ones the walk found.
        var standardCaches: Int
        var memory: BorrowerMemory.State
        var lifts: Int
        /// nil when the process list could not be read.
        var processes: Processes?
    }

    /// A row in the per-area listing, marked when the dashboard ticks it to begin with or only a re-proof cleared it.
    nonisolated static func rowLine(_ row: CleanupCandidate) -> String {
        var line = "    \(row.lowerBound ? "≥" : "")\(row.bytes.diskText)\t\(row.name)\t\(row.verdict.reason)\t\(row.detail)"
        if row.isPreselected { line += "\t미리 체크" }
        if row.reproved { line += "\t다시 증명" }
        return line
    }

    /// One line per area and state: counts only, never a row's name or path.
    nonisolated static func lines(_ summary: Summary) -> [String] {
        func count(_ title: String, _ rows: [CleanupCandidate]) -> String {
            "\(title): \(rows.count)줄 · 고를 수 있음 \(rows.filter(\.isSelectable).count)"
        }
        let projects = summary.projects
        var lines = [
            count("시뮬레이터 런타임", summary.runtimes),
            count("프로젝트 · Xcode 빌드 캐시", projects.filter { $0.id.hasPrefix("project.derivedData.") }),
            count("프로젝트 · git 이 무시하는 빌드 산출물", projects.filter { $0.id.hasPrefix("project.artifact.") }),
            count("프로젝트 · node_modules", projects.filter { $0.id.hasPrefix("project.nodeModules.") }),
            count("끝난 AI 작업 임시 파일", summary.jobs),
        ]
        if let discovery = summary.discovery {
            lines.append("확장 탐색: 폴더 \(discovery.visited)개 · " + (discovery.partial ? "부분 탐색(예산 소진)" : "끝까지 탐색"))
            lines.append("검사하지 않은 곳: " + (discovery.skipped.isEmpty ? "없음" : discovery.skipped.joined(separator: " · ")))
            lines.append("차용 지도 범위: 표준 빌드 캐시 \(summary.standardCaches)곳 + 찾은 빌드 캐시 \(discovery.derivedData.count)곳")
        } else {
            lines.append("확장 탐색: 하지 않음")
        }
        switch summary.memory {
        case .none: lines.append("차용 기억: 없음")
        case .corrupt: lines.append("차용 기억: 손상")
        case .edges(let edges): lines.append("차용 기억: 정상 · 연결 \(edges.count)개")
        }
        lines.append("다시 증명한 보통 줄: \(summary.lifts)개")
        if let side = summary.processes {
            lines.append("메모리 쪽: 보조 프로세스 합산 " + (side.helpersSummed ? "가능" : "불가") + " · 주인 없는 개발 도구 \(side.orphans)개 · 오래 쉬는 AI 세션 "
                         + (side.idleSessions.map { "\($0)개" } ?? "읽지 못함") + " · 가상 머신·에뮬레이터 \(side.machines)개")
        } else {
            lines.append("메모리 쪽: 프로세스 목록을 읽지 못함")
        }
        return lines
    }

    /// The memory screen's reading taken twice with `between` in the middle, since idle sessions need two; reads only.
    nonisolated static func processes(_ sources: SystemMonitor.ProcessSources, apps: [pid_t: String?], idleAge: TimeInterval, between: () -> Void) -> Summary.Processes? {
        let first = sources.read(previous: nil, apps: apps, idleAge: idleAge)
        guard first.snapshot != nil else { return nil }
        between()
        let second = sources.read(previous: first.snapshot, apps: apps, idleAge: idleAge)
        guard second.snapshot != nil else { return nil }
        return Summary.Processes(helpersSummed: second.owners != nil, orphans: second.orphans.count, idleSessions: second.sessions?.count,
                                 machines: second.machines.count)
    }
}
