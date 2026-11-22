import Foundation
import os
import Testing
@testable import Macbak

// The executor against a temporary folder. Each test breaks one rule and checks what is still on disk afterwards.

private struct Harness {
    let box: Sandbox
    let root: URL
    let audit: CleanupAudit
    let simulatorDeletes = OSAllocatedUnfairLock(initialState: [String]())

    init() throws {
        box = try Sandbox()
        root = try box.folder("Caches")
        audit = CleanupAudit(url: box.root.appending(path: "audit/log.jsonl"))
    }

    func executor(open: [String]? = [], forbidden: [URL] = [], simulators: [SimulatorList.Device]? = [], audit: CleanupAudit? = nil,
                  apps: Set<String>? = [], tools: Set<String>? = []) -> CleanupExecutor {
        let root = root
        let deletes = simulatorDeletes
        let snapshot = open.flatMap { OpenFiles.parse(lsofOutput($0)) }
        return CleanupExecutor(dependencies: CleanupExecutor.Dependencies(
            allowedRoots: { [root] }, forbidden: forbidden, openFiles: { snapshot }, mounts: { [] },
            simulators: { simulators }, deleteSimulator: { udid in deletes.withLock { $0.append(udid) }; return true },
            freeSpace: { 100 }, runningBundleIDs: { apps }, runningTools: { tools }, audit: audit ?? self.audit, retryDelay: .zero))
    }

    func item(_ path: String) throws -> CleanupTarget {
        try ScanSupport.removal(box.folder(path), root: root)
    }

    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: box.root.appending(path: path).path) }
}

private func row(_ id: String, _ targets: [CleanupTarget], evidence: Evidence = Evidence(verified: true, inUse: false, regenerable: true)) -> CleanupCandidate {
    CleanupCandidate(id: id, name: id, detail: "", symbol: "doc", bytes: 1, evidence: evidence, targets: targets, scannedAt: .now)
}

private func run(_ executor: CleanupExecutor, _ rows: [CleanupCandidate]) async -> CleanupExecutor.Report {
    await executor.run(rows) { _ in }
}

@Test func executorDeletesOnlyTheChosenItem() async throws {
    let h = try Harness()
    defer { h.box.remove() }
    // Contents first, then the scan's record of the folder, as a real scan sees it.
    try h.box.file("Caches/a/blob.bin")
    try h.box.file("Caches/b/blob.bin")
    let a = try h.item("Caches/a")

    let report = await run(h.executor(), [row("a", [a])])
    #expect(report.items.map(\.outcome) == [.deleted])
    #expect(!h.exists("Caches/a"))
    #expect(h.exists("Caches/b/blob.bin"))
    let log = try String(contentsOf: h.audit.url, encoding: .utf8).split(separator: "\n")
    #expect(log.count == 3)
}

@Test func executorSkipsAnItemThatIsOpen() async throws {
    let h = try Harness()
    defer { h.box.remove() }
    let a = try h.item("Caches/a")
    let file = try h.box.file("Caches/a/index.db")

    let report = await run(h.executor(open: [file.path]), [row("a", [a])])
    #expect(report.items.first?.outcome == .skipped("지금 쓰는 파일이 있습니다"))
    #expect(h.exists("Caches/a/index.db"))
}

@Test func executorWithoutAnOpenFileSnapshotDeletesNothing() async throws {
    let h = try Harness()
    defer { h.box.remove() }
    let a = try h.item("Caches/a")

    let report = await run(h.executor(open: nil), [row("a", [a])])
    #expect(report.items.first?.outcome == .skipped("열린 파일을 확인하지 못했습니다"))
    #expect(h.exists("Caches/a"))
}

@Test func executorSkipsAnItemReplacedSinceTheScan() async throws {
    let h = try Harness()
    defer { h.box.remove() }
    let a = try h.item("Caches/a")
    try FileManager.default.removeItem(at: a.path)
    try h.box.file("Caches/a/new.bin")

    let report = await run(h.executor(), [row("a", [a])])
    #expect(report.items.first?.outcome == .skipped("검사 뒤에 바뀌었습니다"))
    #expect(h.exists("Caches/a/new.bin"))
}

@Test func executorDoesNotStartWithoutAnAuditRecord() async throws {
    let h = try Harness()
    defer { h.box.remove() }
    let a = try h.item("Caches/a")
    // The audit folder's place is taken by a file, so the start record cannot be written.
    try h.box.file("blocked")
    let blocked = CleanupAudit(url: h.box.root.appending(path: "blocked/log.jsonl"))

    let report = await run(h.executor(audit: blocked), [row("a", [a])])
    #expect(report.refusal != nil)
    #expect(report.items.isEmpty)
    #expect(h.exists("Caches/a"))
}

@Test func executorKeepsGoingAfterARefusal() async throws {
    let h = try Harness()
    defer { h.box.remove() }
    let kept = try h.item("Caches/kept")
    let gone = try h.item("Caches/gone")

    let report = await run(h.executor(forbidden: [kept.path]), [row("kept", [kept]), row("gone", [gone])])
    #expect(report.items.map(\.outcome) == [.skipped("지우지 않도록 정한 위치입니다"), .deleted])
    #expect(h.exists("Caches/kept"))
    #expect(!h.exists("Caches/gone"))
}

@Test func executorRefusesOverlappingRows() async throws {
    let h = try Harness()
    defer { h.box.remove() }
    let outer = try h.item("Caches/a")
    let inner = try h.item("Caches/a/sub")

    let report = await run(h.executor(), [row("outer", [outer]), row("inner", [inner])])
    #expect(report.items.allSatisfy { $0.outcome == .skipped("다른 항목과 경로가 겹칩니다") })
    #expect(h.exists("Caches/a/sub"))
}

@Test func executorChecksAWholeGroupBeforeDeletingAny() async throws {
    let h = try Harness()
    defer { h.box.remove() }
    let a = try h.item("Caches/a")
    let b = try h.item("Caches/b")
    let busy = try h.box.file("Caches/b/index.db")

    let report = await run(h.executor(open: [busy.path]), [row("group", [a, b])])
    #expect(report.items.first?.outcome == .skipped("지금 쓰는 파일이 있습니다"))
    #expect(h.exists("Caches/a"))
    #expect(h.exists("Caches/b"))
}

@Test func executorRefusesRowsThatAreNotSelectable() async throws {
    let h = try Harness()
    defer { h.box.remove() }
    let a = try h.item("Caches/a")

    let report = await run(h.executor(), [row("a", [a], evidence: Evidence(verified: true, inUse: true, regenerable: true))])
    #expect(report.items.first?.outcome == .skipped("정리할 수 있는 상태가 아닙니다"))
    #expect(h.exists("Caches/a"))
}

@Test func executorDeletesOnlyListedFilesThatDidNotChange() async throws {
    let h = try Harness()
    defer { h.box.remove() }
    try h.box.file("Caches/logs/old.log", modified: daysAgo(40))
    let changed = try h.box.file("Caches/logs/changed.log", modified: daysAgo(40))
    let facts = TreeWalk.inspect(h.root.appending(path: "logs"), olderThan: daysAgo(30), collect: true)
    try FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: changed.path)
    try h.box.file("Caches/logs/new.log")
    let folder = h.root.appending(path: "logs")
    let target = CleanupTarget(path: folder, root: h.root, identity: FileIdentity.of(folder.path), action: .removeFiles(facts.listed))

    let report = await run(h.executor(), [row("logs", [target])])
    #expect(report.items.first?.outcome == .partial(deleted: 1, of: 2))
    // A partly deleted row is not reported as deleted, so the lists keep it until the next scan.
    #expect(report.deleted.isEmpty)
    #expect(!h.exists("Caches/logs/old.log"))
    #expect(h.exists("Caches/logs/changed.log"))
    #expect(h.exists("Caches/logs/new.log"))
}

@Test func executorDeletesOnlyAShutDownSimulator() async throws {
    let h = try Harness()
    defer { h.box.remove() }
    let data = try h.box.folder("Devices/X/data")
    func device(_ state: String) -> SimulatorList.Device {
        SimulatorList.Device(udid: "X", name: "iPhone", runtime: "iOS 26", state: state, dataPath: data.path, dataBytes: 1, lastUsed: nil)
    }
    let target = CleanupTarget(path: data, root: h.root, identity: nil, action: .deleteSimulator(udid: "X"))
    var evidence = Evidence(verified: true, inUse: false, regenerable: true)
    evidence.userData = true
    let simulator = row("sim", [target], evidence: evidence)

    let booted = await run(h.executor(simulators: [device("Booted")]), [simulator])
    #expect(booted.items.first?.outcome == .skipped("시뮬레이터가 켜져 있습니다"))
    #expect(h.simulatorDeletes.withLock { $0 }.isEmpty)

    let shutdown = await run(h.executor(simulators: [device("Shutdown")]), [simulator])
    #expect(shutdown.items.first?.outcome == .deleted)
    #expect(h.simulatorDeletes.withLock { $0 } == ["X"])
}

private func guarded(_ id: String, _ target: CleanupTarget, _ guards: CleanupGuards) -> CleanupCandidate {
    CleanupCandidate(id: id, name: id, detail: "", symbol: "doc", bytes: 1, evidence: Evidence(verified: true, inUse: false, regenerable: true),
                     targets: [target], guards: guards, scannedAt: .now)
}

@Test func executorSkipsWhenTheOwningAppNowRuns() async throws {
    let h = try Harness()
    defer { h.box.remove() }
    let a = try h.item("Caches/com.example.app")
    let rows = [guarded("a", a, CleanupGuards(bundleIDs: ["com.example.app"]))]

    #expect(await run(h.executor(apps: ["com.example.app"]), rows).items.first?.outcome == .skipped("앱이 실행 중입니다"))
    #expect(await run(h.executor(apps: nil), rows).items.first?.outcome == .skipped("실행 중인 앱을 확인하지 못했습니다"))
    #expect(h.exists("Caches/com.example.app"))
}

@Test func executorSkipsWhenTheOwningToolRunsOrCannotBeTold() async throws {
    let h = try Harness()
    defer { h.box.remove() }
    let a = try h.item("Caches/tool-cache")
    let rows = [guarded("a", a, CleanupGuards(toolIDs: ["claude-app"]))]

    #expect(await run(h.executor(tools: ["claude-app"]), rows).items.first?.outcome == .skipped("AI 도구가 실행 중입니다"))
    #expect(await run(h.executor(tools: nil), rows).items.first?.outcome == .skipped("AI 도구 실행 여부를 확인하지 못했습니다"))
    #expect(h.exists("Caches/tool-cache"))
}

@Test func executorSkipsWhenTheWorkspaceIsOpen() async throws {
    let h = try Harness()
    defer { h.box.remove() }
    let a = try h.item("Caches/derived")
    let workspace = try h.box.folder("dev/app")
    let rows = [guarded("a", a, CleanupGuards(watchPaths: [workspace]))]

    let report = await run(h.executor(open: [workspace.path + "/Sources/main.swift"]), rows)
    #expect(report.items.first?.outcome == .skipped("작업 공간에서 쓰는 파일이 있습니다"))
    #expect(h.exists("Caches/derived"))
}

@Test func executorRefusesRowsFromAnOldOrUnknownScan() async throws {
    let h = try Harness()
    defer { h.box.remove() }
    let old = try h.item("Caches/old"), unknown = try h.item("Caches/unknown"), fresh = try h.item("Caches/fresh")
    var stale = row("old", [old])
    stale.scannedAt = Date.now.addingTimeInterval(-(CleanupCandidate.resultLifetime + 60))
    var unstamped = row("unknown", [unknown])
    unstamped.scannedAt = nil

    let report = await run(h.executor(), [stale, unstamped, row("fresh", [fresh])])
    #expect(report.items.map(\.outcome) == [.skipped("검사한 지 오래돼 다시 검사해야 합니다"),
                                             .skipped("검사한 지 오래돼 다시 검사해야 합니다"), .deleted])
    #expect(h.exists("Caches/old") && h.exists("Caches/unknown") && !h.exists("Caches/fresh"))
}

@Test func executorNoticesAnAppStartedDuringTheRun() async throws {
    let h = try Harness()
    defer { h.box.remove() }
    let a = try h.item("Caches/com.example.a"), b = try h.item("Caches/com.example.b")
    // The first reading sees nothing running; by the second, app b has started.
    let readings = OSAllocatedUnfairLock(initialState: [Set<String>(), ["com.example.b"]])
    let root = h.root
    // Default lifetimes on purpose: the two rows are checked well within five seconds, so any reuse would miss app b.
    let dependencies = CleanupExecutor.Dependencies(
        allowedRoots: { [root] }, forbidden: [], openFiles: { OpenFiles.parse(lsofOutput([])) }, mounts: { [] },
        simulators: { [] }, deleteSimulator: { _ in true }, freeSpace: { 100 },
        runningBundleIDs: { readings.withLock { $0.count > 1 ? $0.removeFirst() : $0[0] } }, runningTools: { [] },
        audit: h.audit, retryDelay: .zero)
    let rows = [guarded("a", a, CleanupGuards(bundleIDs: ["com.example.a"])), guarded("b", b, CleanupGuards(bundleIDs: ["com.example.b"]))]

    let report = await run(CleanupExecutor(dependencies: dependencies), rows)
    #expect(report.items.map(\.outcome) == [.deleted, .skipped("앱이 실행 중입니다")])
    #expect(!h.exists("Caches/com.example.a") && h.exists("Caches/com.example.b"))
}

@Test func executorRefusesAFolderThatGainedAnEntryAfterTheScan() async throws {
    let h = try Harness()
    defer { h.box.remove() }
    try h.box.file("Caches/result-bundles/old.xcresult/Info.plist")
    let bundles = try h.item("Caches/result-bundles")
    // A test run finished after the scan and left a new result directly inside.
    try h.box.file("Caches/result-bundles/new.xcresult/Info.plist")

    let report = await run(h.executor(), [row("bundles", [bundles])])
    #expect(report.items.first?.outcome == .skipped("검사 뒤에 바뀌었습니다"))
    #expect(h.exists("Caches/result-bundles/new.xcresult/Info.plist"))
}

@Test func executorAsksTheOwnerAgainBeforeARetry() async throws {
    let h = try Harness()
    defer { h.box.remove() }
    // A read-only folder inside makes the first attempt fail, so the executor waits and retries.
    let locked = try h.box.folder("Caches/com.example.a/locked")
    try h.box.file("Caches/com.example.a/locked/blob.bin")
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
    let a = try h.item("Caches/com.example.a")
    // Idle when the row is checked; running by the time of the retry.
    let readings = OSAllocatedUnfairLock(initialState: [Set<String>(), ["com.example.a"]])
    let root = h.root
    let dependencies = CleanupExecutor.Dependencies(
        allowedRoots: { [root] }, forbidden: [], openFiles: { OpenFiles.parse(lsofOutput([])) }, mounts: { [] },
        simulators: { [] }, deleteSimulator: { _ in true }, freeSpace: { 100 },
        runningBundleIDs: { readings.withLock { $0.count > 1 ? $0.removeFirst() : $0[0] } }, runningTools: { [] },
        audit: h.audit, retryDelay: .zero)

    let report = await run(CleanupExecutor(dependencies: dependencies), [guarded("a", a, CleanupGuards(bundleIDs: ["com.example.a"]))])
    #expect(report.items.first?.outcome == .failed("다시 시도하기 전에 바뀌어서 그만둠"))
}

private func finderReply(_ text: String, status: Int32 = 0) -> Command.Output { Command.Output(status: status, stdout: Data(text.utf8)) }

@Test func trashIsNotEmptiedWithoutAnAuditRecord() throws {
    let h = try Harness()
    defer { h.box.remove() }
    try h.box.file("blocked")
    let asked = OSAllocatedUnfairLock(initialState: 0)
    let emptier = TrashEmptier(askFinder: { asked.withLock { $0 += 1 }; return finderReply("ok") }, freeSpace: { 100 },
                               audit: CleanupAudit(url: h.box.root.appending(path: "blocked/log.jsonl")), settle: .zero)

    #expect(emptier.run() == .init(emptied: false, message: "정리 기록을 남길 수 없어 비우지 않았습니다"))
    #expect(asked.withLock { $0 } == 0)
}

@Test func trashEmptyingIsRecordedAndMeasured() throws {
    let h = try Harness()
    defer { h.box.remove() }
    let free = OSAllocatedUnfairLock(initialState: [Int64(100), 2_100_000_100])
    let emptier = TrashEmptier(askFinder: { finderReply("ok\n") }, freeSpace: { free.withLock { $0.removeFirst() } }, audit: h.audit, settle: .zero)

    let result = emptier.run()
    #expect(result.emptied)
    #expect(result.message.hasPrefix("휴지통을 비웠습니다 · 실제로 늘어난 공간"))
    let log = try String(contentsOf: h.audit.url, encoding: .utf8)
    #expect(log.contains("trash-start") && log.contains("trash-end") && !log.contains("paths"))
}

@Test func finderRepliesAreToldApart() {
    #expect(TrashEmptier.result(finderReply("error -1743"), gain: "").message.hasPrefix("Finder를 제어할 권한이 없습니다"))
    #expect(TrashEmptier.result(nil, gain: "") == .init(emptied: false, message: "Finder에 요청하지 못했습니다"))
    #expect(TrashEmptier.result(finderReply("error -128"), gain: "") == .init(emptied: false, message: "Finder가 비우지 못했습니다 (error -128)"))
    #expect(!TrashEmptier.result(finderReply("ok", status: 1), gain: "").emptied)
}

@Test func executorStopsARowWhenItsAppStartsBetweenTargets() async throws {
    let h = try Harness()
    defer { h.box.remove() }
    try h.box.file("Caches/com.example.a/one/blob.bin")
    try h.box.file("Caches/com.example.a/two/blob.bin")
    let one = try h.item("Caches/com.example.a/one"), two = try h.item("Caches/com.example.a/two")
    // Idle when the row is checked; running by the second target.
    let readings = OSAllocatedUnfairLock(initialState: [Set<String>(), ["com.example.a"]])
    let root = h.root
    let dependencies = CleanupExecutor.Dependencies(
        allowedRoots: { [root] }, forbidden: [], openFiles: { OpenFiles.parse(lsofOutput([])) }, mounts: { [] },
        simulators: { [] }, deleteSimulator: { _ in true }, freeSpace: { 100 },
        runningBundleIDs: { readings.withLock { $0.count > 1 ? $0.removeFirst() : $0[0] } }, runningTools: { [] },
        audit: h.audit, retryDelay: .zero)
    let row = CleanupCandidate(id: "a", name: "a", detail: "", symbol: "doc", bytes: 1, evidence: Evidence(verified: true, inUse: false, regenerable: true),
                               targets: [one, two], guards: CleanupGuards(bundleIDs: ["com.example.a"]), scannedAt: .now)

    let report = await run(CleanupExecutor(dependencies: dependencies), [row])
    #expect(report.items.first?.outcome == .partial(deleted: 1, of: 2))
    #expect(!h.exists("Caches/com.example.a/one") && h.exists("Caches/com.example.a/two/blob.bin"))
}

@Test func executorDoesNotRetryAListedFileThatWasOpenedMeanwhile() async throws {
    let h = try Harness()
    defer { h.box.remove() }
    try h.box.file("Caches/logs/old.log", modified: daysAgo(40))
    let logs = h.root.appending(path: "logs")
    let facts = TreeWalk.inspect(logs, olderThan: daysAgo(30), collect: true)
    let listed = try #require(facts.listed.first)
    let target = CleanupTarget(path: logs, root: h.root, identity: FileIdentity.of(logs.path), action: .removeFiles(facts.listed))
    // A read-only folder makes the first attempt fail; by the retry, another process has the file open.
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: logs.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: logs.path) }
    let snapshots = OSAllocatedUnfairLock(initialState: [[String](), [listed.path]])
    let root = h.root
    let dependencies = CleanupExecutor.Dependencies(
        allowedRoots: { [root] }, forbidden: [],
        openFiles: { OpenFiles.parse(lsofOutput(snapshots.withLock { $0.count > 1 ? $0.removeFirst() : $0[0] })) }, mounts: { [] },
        simulators: { [] }, deleteSimulator: { _ in true }, freeSpace: { 100 }, runningBundleIDs: { [] }, runningTools: { [] },
        audit: h.audit, retryDelay: .zero)

    let report = await run(CleanupExecutor(dependencies: dependencies), [row("logs", [target])])
    #expect(report.items.first?.outcome == .failed("다시 시도하기 전에 바뀌어서 그만둠"))
}

@Test func liveFreeSpaceReadingsSeeAChange() throws {
    let h = try Harness()
    defer { h.box.remove() }
    // The injected readings in other tests cannot catch this: a reused URL kept its first value, so every clean-up
    // reported no change. Writing 200 MB must show up in the readings the app actually uses.
    let readers: [@Sendable () -> Int64?] = [CleanupExecutor.Dependencies.live().freeSpace, TrashEmptier.live().freeSpace]
    let before = readers.map { $0() }
    try Data(count: 200_000_000).write(to: h.box.root.appending(path: "blob.bin"))
    let after = readers.map { $0() }
    for (b, a) in zip(before, after) {
        let drop = try #require(b) - (try #require(a))
        #expect(drop > 100_000_000)
    }
}

/// A row the screens now hold or protect — a rescan or the on-device model changed its verdict after the list was handed
/// over — is skipped; the rest of the list still goes.
@Test func executorSkipsARowWhoseLatestVerdictCannotBeChosen() async throws {
    let h = try Harness()
    defer { h.box.remove() }
    try h.box.file("Caches/a/blob.bin")
    try h.box.file("Caches/b/blob.bin")
    let a = try h.item("Caches/a"), b = try h.item("Caches/b")
    var held = Evidence(verified: true, inUse: false, regenerable: true)
    held.awaitingModel = true
    let now = row("b", [b], evidence: held)

    let report = await h.executor().run([row("a", [a]), row("b", [b])], latest: { id in id == "b" ? now : nil }) { _ in }
    #expect(report.items.map(\.outcome) == [.deleted, .skipped("다시 검사한 결과 지금은 고를 수 없습니다")])
    #expect(!h.exists("Caches/a"))
    #expect(h.exists("Caches/b/blob.bin"))
}

/// The runner both screens share passes its view of the latest rows down to the executor.
@MainActor
@Test func runnerAsksTheLatestRowsBeforeDeleting() async throws {
    let h = try Harness()
    defer { h.box.remove() }
    try h.box.file("Caches/b/blob.bin")
    let b = try h.item("Caches/b")
    let protected = row("b", [b], evidence: Evidence(verified: true, inUse: true, regenerable: true))
    let runner = CleanupRunner(executor: h.executor(), latest: { id in id == "b" ? protected : nil })

    let report = await runner.run([row("b", [b])]) { _ in }
    #expect(report.items.map(\.outcome) == [.skipped("다시 검사한 결과 지금은 고를 수 없습니다")])
    #expect(h.exists("Caches/b/blob.bin"))
}

@MainActor
private final class Events {
    var list: [String] = []
}

/// A run first waits for a scan in progress, then hands rows to the executor, which asks for the latest verdicts.
@MainActor
@Test func runnerWaitsForAScanBeforeDeleting() async throws {
    let h = try Harness()
    defer { h.box.remove() }
    try h.box.file("Caches/b/blob.bin")
    let b = try h.item("Caches/b")
    let events = Events()
    let runner = CleanupRunner(executor: h.executor(), latest: { _ in events.list.append("latest"); return nil },
                               settle: { events.list.append("settle") })

    _ = await runner.run([row("b", [b])]) { _ in }
    #expect(events.list == ["settle", "latest"])
}

/// "중단" during a run: the row being deleted finishes, none after it starts, each one left says why, and the next run
/// starts unstopped.
@MainActor
@Test func stoppingARunLeavesTheRowsAfterTheOneBeingDeleted() async throws {
    let h = try Harness()
    defer { h.box.remove() }
    var rows: [CleanupCandidate] = []
    for name in ["a", "b", "c"] {
        try h.box.file("Caches/\(name)/blob.bin")
        rows.append(row(name, [try h.item("Caches/\(name)")]))
    }
    let runner = CleanupRunner(executor: h.executor())
    // Pressed while "a" is reported done, before "b" starts.
    let report = await runner.run(rows) { _ in runner.stop() }
    #expect(report.items.map(\.outcome) == [.deleted, .skipped("중단해서 지우지 않았습니다"), .skipped("중단해서 지우지 않았습니다")])
    #expect(!h.exists("Caches/a/blob.bin") && h.exists("Caches/b/blob.bin") && h.exists("Caches/c/blob.bin"))
    #expect(!runner.isStopping)
    runner.stop()  // nothing running: ignored
    #expect(await runner.run([rows[1]]) { _ in }.items.map(\.outcome) == [.deleted])
}

@MainActor
private final class RunnerBox {
    weak var runner: CleanupRunner?
}

/// The menu footer's stop is the loop's: a screen's run, which the loop may be waiting for, does not count as the loop's,
/// so stopping from the footer can never stop it while the loop goes on to delete.
@MainActor
@Test func onlyTheLoopsOwnRunIsTheLoops() async throws {
    let h = try Harness()
    defer { h.box.remove() }
    try h.box.file("Caches/b/blob.bin")
    let b = try h.item("Caches/b")
    let events = Events(), box = RunnerBox()
    let runner = CleanupRunner(executor: h.executor(), latest: { _ in events.list.append(box.runner?.isLoopRun == true ? "loop" : "screen"); return nil })
    box.runner = runner
    _ = await runner.run([row("b", [b])]) { _ in }
    var vouched = row("b", [b])
    vouched.trusted = true
    _ = await runner.runShallow([vouched])
    #expect(events.list == ["screen", "loop"])
    #expect(!runner.isLoopRun)
}

/// An open-file snapshot ages from when `lsof` started. One 0.6 s capture plus 0.5 s spent asking which apps run is
/// 1.1 s old, past a 1 s window, so it is captured again right before the folder goes; aged from its end it read 0.5 s
/// and was reused. A capture that alone takes longer than the window is refused, and nothing is deleted by it.
@Test func anOpenFileSnapshotAgesFromWhenItWasStarted() async throws {
    let h = try Harness()
    defer { h.box.remove() }
    try h.box.file("Caches/a/blob.bin")
    try h.box.file("Caches/b/blob.bin")
    func executor(capture: TimeInterval, counter: OSAllocatedUnfairLock<Int>) -> CleanupExecutor {
        CleanupExecutor(dependencies: CleanupExecutor.Dependencies(
            allowedRoots: { [h.root] }, forbidden: [],
            openFiles: {
                counter.withLock { $0 += 1 }
                Thread.sleep(forTimeInterval: capture)
                return OpenFiles.parse(lsofOutput([]))
            },
            mounts: { [] }, simulators: { [] }, deleteSimulator: { _ in false }, freeSpace: { 100 },
            runningBundleIDs: {
                try? await Task.sleep(for: .milliseconds(500))
                return []
            },
            runningTools: { [] }, audit: h.audit, snapshotLifetime: 1, retryDelay: .zero))
    }
    var owned = row("a", [try h.item("Caches/a")])
    owned.guards = CleanupGuards(bundleIDs: ["com.example.app"])
    let captures = OSAllocatedUnfairLock(initialState: 0)
    #expect(await executor(capture: 0.6, counter: captures).run([owned]) { _ in }.items.map(\.outcome) == [.deleted])
    #expect(captures.withLock { $0 } == 2)

    let slow = await executor(capture: 1.2, counter: OSAllocatedUnfairLock(initialState: 0)).run([row("b", [try h.item("Caches/b")])]) { _ in }
    #expect(slow.items.map(\.outcome) == [.skipped("열린 파일을 확인하지 못했습니다")])
    #expect(h.exists("Caches/b/blob.bin"))
}

/// A run nobody chose walks a folder again before deleting it, which can take a minute; the owning app is asked after that
/// walk, not only before it. Here the app starts after the row's up-front check, and the folder stays.
@Test func anAppStartedDuringTheWalkBeforeDeletingKeepsItsCache() async throws {
    let h = try Harness()
    defer { h.box.remove() }
    try h.box.file("Caches/xcode/blob.bin")
    let asked = OSAllocatedUnfairLock(initialState: 0)
    let executor = CleanupExecutor(dependencies: CleanupExecutor.Dependencies(
        allowedRoots: { [h.root] }, forbidden: [], openFiles: { OpenFiles.parse(lsofOutput([])) }, mounts: { [] },
        simulators: { [] }, deleteSimulator: { _ in false }, freeSpace: { 100 },
        runningBundleIDs: { asked.withLock { $0 += 1; return $0 } == 1 ? [] : ["com.apple.dt.Xcode"] },
        runningTools: { [] }, audit: h.audit, retryDelay: .zero))
    var shared = row("xcode.shared", [try h.item("Caches/xcode")])
    shared.guards = CleanupGuards(bundleIDs: ["com.apple.dt.Xcode"])
    shared.trusted = true
    let rows = [shared]
    let report = await executor.run(rows, latest: { id in rows.first { $0.id == id } }, shallow: true) { _ in }
    #expect(report.items.map(\.outcome) == [.failed("앱이 실행 중입니다")])
    #expect(h.exists("Caches/xcode/blob.bin"))
}

/// Each folder of a row is checked right before it goes, not only before the first: a later one opened while an earlier
/// one was being deleted stays, and the row reads as partly deleted.
@Test func aTargetOpenedWhileAnEarlierOneIsDeletedStays() async throws {
    let h = try Harness()
    defer { h.box.remove() }
    try h.box.file("Caches/a/blob.bin")
    try h.box.file("Caches/b/blob.bin")
    let a = try h.item("Caches/a"), b = try h.item("Caches/b")
    let aPath = a.path.path(percentEncoded: false), inB = b.path.appending(path: "blob.bin").path(percentEncoded: false)
    // Nothing is open until "a" is gone; then something opens a file in "b". Asking which apps run between the two takes
    // 0.1 s, so the snapshot taken before "a" (0.05 s window) is too old by then and is taken again.
    let executor = CleanupExecutor(dependencies: CleanupExecutor.Dependencies(
        allowedRoots: { [h.root] }, forbidden: [],
        openFiles: { OpenFiles.parse(lsofOutput(FileManager.default.fileExists(atPath: aPath) ? [] : [inB])) },
        mounts: { [] }, simulators: { [] }, deleteSimulator: { _ in false }, freeSpace: { 100 },
        runningBundleIDs: {
            try? await Task.sleep(for: .milliseconds(100))
            return []
        },
        runningTools: { [] }, audit: h.audit, snapshotLifetime: 0.05, retryDelay: .zero))
    var both = row("ab", [a, b])
    both.guards = CleanupGuards(bundleIDs: ["com.example.app"])
    let report = await executor.run([both]) { _ in }
    #expect(report.items.map(\.outcome) == [.partial(deleted: 1, of: 2)])
    #expect(!h.exists("Caches/a/blob.bin") && h.exists("Caches/b/blob.bin"))
}

/// The loop's record must not read "얕은 정리 0개" when there was something to delete and nothing could be: that is a
/// failure (here the open-file list cannot be read), not an empty Mac.
@MainActor
@Test func aLoopRunThatCouldDeleteNothingIsAFailure() async throws {
    let h = try Harness()
    defer { h.box.remove() }
    try h.box.file("Caches/b/blob.bin")
    var vouched = row("b", [try h.item("Caches/b")])
    vouched.trusted = true
    let current = vouched
    let runner = CleanupRunner(executor: h.executor(open: nil), latest: { _ in current })
    #expect(await runner.runShallow([current]) == nil)
    #expect(await runner.runShallow([])?.isEmpty == true)
    #expect(h.exists("Caches/b/blob.bin"))
}

/// Whoever starts a run, the rows it deleted leave the lists every screen reads: the dashboard once only hid them in its
/// own view, so the menu offered them again with their size.
@MainActor
@Test func aRunDropsWhatItDeletedFromTheSharedLists() async throws {
    let h = try Harness()
    defer { h.box.remove() }
    try h.box.file("Caches/a/blob.bin")
    let events = Events()
    let runner = CleanupRunner(executor: h.executor(), forget: { ids in events.list += ids.sorted() })
    _ = await runner.run([row("a", [try h.item("Caches/a")]), row("gone", [try h.item("Caches/gone")], evidence: Evidence(verified: true, inUse: true, regenerable: true))]) { _ in }
    #expect(events.list == ["a"])
}

/// The loop's clean-up deletes only ready rows a source vouches for; a ready row without one and a row that needs a
/// choice stay on disk.
@MainActor
@Test func theShallowCleanUpDeletesOnlyVouchedReadyRows() async throws {
    let h = try Harness()
    defer { h.box.remove() }
    try h.box.file("Caches/vouched/blob.bin")
    try h.box.file("Caches/unvouched/blob.bin")
    try h.box.file("Caches/choice/blob.bin")
    var vouched = row("vouched", [try h.item("Caches/vouched")])
    vouched.trusted = true
    let unvouched = row("unvouched", [try h.item("Caches/unvouched")])
    var choice = row("choice", [try h.item("Caches/choice")], evidence: Evidence(verified: true, inUse: false, regenerable: true, downloadCost: true))
    choice.trusted = true
    let rows = [vouched, unvouched, choice]
    let runner = CleanupRunner(executor: h.executor(), latest: { id in rows.first { $0.id == id } })

    let deleted = await runner.runShallow(rows)
    #expect(deleted?.map(\.id) == ["vouched"])
    #expect(!h.exists("Caches/vouched"))
    #expect(h.exists("Caches/unvouched/blob.bin") && h.exists("Caches/choice/blob.bin"))
}

/// A run nobody chose row by row deletes a row only if, just before, the screens still hold it as shallow with the same
/// targets: not when a rescan made it a choice, dropped it, or changed what it would delete.
@Test func aShallowRunNeedsTheRowToStillBeShallow() async throws {
    let h = try Harness()
    defer { h.box.remove() }
    for name in ["same", "choice", "gone", "moved", "other"] { try h.box.file("Caches/\(name)/blob.bin") }
    func shallow(_ id: String, _ path: String) throws -> CleanupCandidate {
        var row = row(id, [try h.item(path)])
        row.trusted = true
        return row
    }
    let handed = [try shallow("same", "Caches/same"), try shallow("choice", "Caches/choice"), try shallow("gone", "Caches/gone"),
                  try shallow("moved", "Caches/moved")]
    var nowChoice = row("choice", handed[1].targets, evidence: Evidence(verified: true, inUse: false, regenerable: true, downloadCost: true))
    nowChoice.trusted = true
    let nowMoved = try shallow("moved", "Caches/other")
    let current = ["same": handed[0], "choice": nowChoice, "moved": nowMoved]

    let report = await h.executor().run(handed, latest: { id in current[id] }, shallow: true) { _ in }
    #expect(report.deleted.map(\.id) == ["same"])
    for name in ["choice", "gone", "moved"] { #expect(h.exists("Caches/\(name)/blob.bin"), "\(name)") }
}

/// A run nobody chose walks each target again just before deleting it: a wallet copied deep inside after the scan —
/// which leaves the target's own identity as it was — stops the row. A row the person chose is not walked again.
@Test func aShallowRunSeesAWalletAddedDeepAfterTheScan() async throws {
    let h = try Harness()
    defer { h.box.remove() }
    try h.box.file("Caches/a/b/blob.bin")
    var row = row("a", [try h.item("Caches/a")])
    row.trusted = true
    try h.box.file("Caches/a/b/c/wallet.dat")
    let current = row

    let report = await h.executor().run([row], latest: { _ in current }, shallow: true) { _ in }
    #expect(report.deleted.isEmpty)
    #expect(h.exists("Caches/a/b/c/wallet.dat"))
}

/// With several targets in a shallow row, each is walked again right before it is deleted, not only in the row's
/// up-front check: a wallet put into the second target after that check (here, while the executor asks which apps run
/// between targets) stops the row there, and the wallet stays.
@Test func aShallowRunWalksEachTargetRightBeforeDeletingIt() async throws {
    let h = try Harness()
    defer { h.box.remove() }
    try h.box.file("Caches/first/blob.bin")
    try h.box.file("Caches/second/deep/blob.bin")
    let first = try h.item("Caches/first"), second = try h.item("Caches/second")
    var shallow = CleanupCandidate(id: "row", name: "row", detail: "", symbol: "doc", bytes: 1,
                                   evidence: Evidence(verified: true, inUse: false, regenerable: true), targets: [first, second],
                                   guards: CleanupGuards(bundleIDs: ["com.example.owner"]), scannedAt: .now)
    shallow.trusted = true
    let asked = OSAllocatedUnfairLock(initialState: 0)
    let wallet = h.box.root.appending(path: "Caches/second/deep/wallet.dat")
    let root = h.root
    let snapshot = OpenFiles.parse(lsofOutput([]))
    let executor = CleanupExecutor(dependencies: CleanupExecutor.Dependencies(
        allowedRoots: { [root] }, forbidden: [], openFiles: { snapshot }, mounts: { [] }, simulators: { [] }, deleteSimulator: { _ in true },
        freeSpace: { 100 },
        runningBundleIDs: {
            // Asked up front and before each further target; on the ask before the second target, a wallet arrives.
            if asked.withLock({ $0 += 1; return $0 }) == 2 { try? Data([1]).write(to: wallet) }
            return []
        },
        runningTools: { [] }, audit: h.audit, retryDelay: .zero))
    let current = shallow

    let report = await executor.run([shallow], latest: { _ in current }, shallow: true) { _ in }
    #expect(!h.exists("Caches/first"))
    #expect(h.exists("Caches/second/deep/wallet.dat"))
    #expect(report.deleted.isEmpty)
}

/// Even a row marked shallow (a future scanner bug) cannot make a run nobody chose delete a simulator.
@Test func aShallowRunNeverDeletesASimulator() async throws {
    let h = try Harness()
    defer { h.box.remove() }
    let data = try h.box.file("Devices/quiet/data/Library/blob", modified: daysAgo(10)).deletingLastPathComponent().deletingLastPathComponent()
    let device = SimulatorList.Device(udid: "quiet", name: "quiet", runtime: "iOS 27.0", state: "Shutdown", dataPath: data.path(percentEncoded: false),
                                      dataBytes: 2_000_000, lastUsed: daysAgo(10))
    var row = CleanupCandidate(id: "simulator.quiet", name: "quiet", detail: "", symbol: "ipad", bytes: 1,
                               evidence: Evidence(verified: true, inUse: false, regenerable: true),
                               targets: [CleanupTarget(path: data, root: h.box.root, identity: nil, action: .deleteSimulator(udid: "quiet"))],
                               lastUsed: daysAgo(10), scannedAt: .now)
    row.trusted = true
    let rows = [row]
    let shallow = await h.executor(simulators: [device]).run(rows, latest: { id in rows.first { $0.id == id } }, shallow: true) { _ in }
    #expect(h.simulatorDeletes.withLock { $0 }.isEmpty)
    #expect(shallow.items.first?.outcome == .skipped("시뮬레이터는 목록을 보고 골라야 지웁니다"))
    // The same row chosen on the dashboard goes.
    let chosen = await h.executor(simulators: [device]).run(rows) { _ in }
    #expect(chosen.items.first?.outcome == .deleted)
}
