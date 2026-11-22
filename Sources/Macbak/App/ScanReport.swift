import Foundation

/// `--scan-report`: scans the real disk the way the disk screen does and prints every candidate with its verdict, then
/// exits. Read-only — it never deletes — so a scanner change can be checked against the actual Mac before any clean-up.
@MainActor
enum ScanReport {
    static func run() {
        let coordinator = CleanupCoordinator()
        // AI tool caches too, the way the app scans them: AI processes first, so unused caches can be told.
        let ai = AIMonitor(isWindowShown: { true })
        let storage = AIStorage()
        let started = Date.now
        var finished = false
        Task {
            await coordinator.scan()
            await ai.wake()
            await storage.scan(using: ai)
            finished = true
        }
        while !finished, Date.now.timeIntervalSince(started) < 900 { RunLoop.main.run(until: .now.addingTimeInterval(0.5)) }
        print(String(format: "scan: %.1fs%@", Date.now.timeIntervalSince(started), finished ? "" : " (timed out)"))

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

        for area in CleanupCoordinator.Area.allCases {
            let found = coordinator.candidates[area] ?? []
            print("\n== \(area.title): \(found.count)")
            for status in CleanupStatus.allCases {
                let rows = found.filter { $0.verdict.status == status }
                guard !rows.isEmpty else { continue }
                print("  [\(status.title)] \(rows.count)개 · \(rows.reduce(0) { $0 + $1.bytes }.diskText)")
                for row in rows {
                    print("    \(row.lowerBound ? "≥" : "")\(row.bytes.diskText)\t\(row.name)\t\(row.verdict.reason)\t\(row.detail)")
                }
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
        // Simulators are deleted with `simctl delete`, which the path guard never sees.
        let unreachable = rows.filter(\.isSelectable).filter { row in
            row.targets.contains { target in
                if case .deleteSimulator = target.action { return false }
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
}
