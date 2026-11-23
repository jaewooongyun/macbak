import Foundation
import Testing
@testable import Macbak

/// The wait after a run that deleted simulators or runtimes. Everything it reads is replaced: the temp folder's
/// `Deleting-*` names, which paths exist, the runtime listing and free space all answer by stage, and the fake sleep
/// moves the stage on, so fifteen minutes pass at once. Nothing is deleted.
@Suite struct BackgroundDeletionTests {
    final class World: @unchecked Sendable {
        private let lock = NSLock()
        private var stage = 0
        private(set) var sleeps = 0
        var names: (Int) -> Set<String>? = { _ in [] }
        var existing: (Int, String) -> Bool = { _, _ in false }
        var listed: (Int) -> [SimulatorRuntimes.Runtime]? = { _ in [] }
        var free: (Int) -> Int64? = { _ in nil }

        private var seen: [Int64?] = []
        var now: Int { lock.withLock { stage } }
        var readings: [Int64?] { lock.withLock { seen } }
        func read(_ free: Int64?) { lock.withLock { seen.append(free) } }
        func advance() { lock.withLock { stage += 1; sleeps += 1 } }
    }

    static func waiter(_ world: World, audit: URL, checks: Int = 180) -> BackgroundDeletion {
        BackgroundDeletion(dependencies: .init(
            deletingNames: { world.names(world.now) }, exists: { world.existing(world.now, $0) }, runtimes: { world.listed(world.now) },
            freeSpace: { world.free(world.now) }, sleep: { _ in world.advance() }, audit: CleanupAudit(url: audit), checks: checks))
    }

    static func settledRecords(_ audit: URL) -> [[String: String]] {
        guard let text = try? String(contentsOf: audit, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: String]
        }.filter { $0["event"] == "settled" }
    }

    static let device = BackgroundDeletion.Pending.simulator(udid: "A", dataPath: "/fake/A/data", traces: ["Deleting-1"])

    // MARK: Waiting

    @Test func itMeasuresOnlyOnceTheTracesAndTheFolderAreGone() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let audit = box.root.appending(path: "audit.jsonl")
        let world = World()
        // The trace stays two checks, the data folder one more; free space 120 right after the run, 170 once all is gone.
        world.names = { $0 < 2 ? ["Deleting-1", "Deleting-other"] : ["Deleting-other"] }
        world.existing = { stage, _ in stage < 3 }
        world.free = { $0 < 3 ? 140 : 170 }
        let result = try #require(await Self.waiter(world, audit: audit).wait(for: [Self.device], free: 120) { world.read($0) })
        #expect(result.state == .settled && result.free == 170)
        #expect(world.sleeps == 3 && world.readings == [140, 140])
        #expect(BackgroundDeletion.text(result.state, freeBefore: 100, free: result.free) == "실제로 늘어난 공간 +\(Int64(70).diskText) (삭제가 끝난 뒤 측정)")
        let settled = Self.settledRecords(audit)
        #expect(settled.count == 1 && settled.first?["freeAfter"] == "170")
    }

    @Test func aDeleteWhoseTracesWereNeverSeenProvesNothing() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let audit = box.root.appending(path: "audit.jsonl")
        let unseen = BackgroundDeletion.Pending.simulator(udid: "B", dataPath: "/fake/B/data", traces: [])
        for pending in [[unseen], [Self.device, unseen], [.simulator(udid: "C", dataPath: "/fake/C", traces: nil)]] {
            let result = try #require(await Self.waiter(World(), audit: audit).wait(for: pending, free: 120))
            #expect(result.state == .unconfirmed && result.free == 120)
            #expect(BackgroundDeletion.text(result.state, freeBefore: 100, free: result.free).hasPrefix("삭제가 끝났는지 확인하지 못했습니다 · 지금까지 +"))
        }
        #expect(Self.settledRecords(audit).isEmpty)
    }

    @Test func aFolderThatStaysIsStillBeingDeletedAtTheLimit() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let audit = box.root.appending(path: "audit.jsonl")
        let world = World()
        world.existing = { _, _ in true }
        let result = try #require(await Self.waiter(world, audit: audit, checks: 4).wait(for: [Self.device], free: 120))
        #expect(result.state == .stillDeleting && world.sleeps == 4)
        #expect(Self.settledRecords(audit).isEmpty)
    }

    @Test func aRuntimeIsGoneOnceUnlistedAndItsImageIsGone() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let audit = box.root.appending(path: "audit.jsonl")
        let image = SimulatorRuntimes.Runtime(identifier: "R", runtimeIdentifier: "k", build: "1", deletable: true, path: "/fake/image",
                                              bytes: 1, lastUsed: nil)
        let world = World()
        world.listed = { $0 < 1 ? [image] : [] }
        world.existing = { stage, path in path == "/fake/image" && stage < 2 }
        world.free = { _ in 170 }
        let pending = [BackgroundDeletion.Pending.runtime(identifier: "R", path: "/fake/image")]
        let result = try #require(await Self.waiter(world, audit: audit).wait(for: pending, free: 120))
        #expect(result.state == .settled && world.sleeps == 2)

        let failing = World()
        failing.listed = { _ in nil }
        #expect(await Self.waiter(failing, audit: audit).wait(for: pending, free: 120)?.state == .unconfirmed)
    }

    @Test func anUnreadableTempFolderIsUnconfirmed() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let world = World()
        world.names = { _ in nil }
        #expect(await Self.waiter(world, audit: box.root.appending(path: "a.jsonl")).wait(for: [Self.device], free: 120)?.state == .unconfirmed)
    }

    @Test func aMissingReadingLeavesTheGainUnmeasured() {
        #expect(BackgroundDeletion.text(.settled, freeBefore: nil, free: 170) == "늘어난 공간을 재지 못했습니다")
        #expect(BackgroundDeletion.text(.settled, freeBefore: 100, free: nil) == "늘어난 공간을 재지 못했습니다")
    }

    @Test func nothingPendingMeansNoWait() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let world = World()
        #expect(await Self.waiter(world, audit: box.root.appending(path: "a.jsonl")).wait(for: [], free: 120) == nil)
        #expect(world.sleeps == 0)
    }

    @Test func cancellingReturnsAtOnce() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        var dependencies = Self.waiter(World(), audit: box.root.appending(path: "a.jsonl")).dependencies
        dependencies.exists = { _ in true }
        dependencies.sleep = { try await Task.sleep(for: $0) }
        dependencies.interval = .seconds(60)
        let waiter = BackgroundDeletion(dependencies: dependencies)
        let task = Task { await waiter.wait(for: [Self.device], free: 120) }
        try await Task.sleep(for: .milliseconds(100))
        let started = Date.now
        task.cancel()
        #expect(await task.value?.state == .cancelled)
        #expect(Date.now.timeIntervalSince(started) < 2)
    }

    final class Texts: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ line: String) { lock.withLock { lines.append(line) } }
        var all: [String] { lock.withLock { lines } }
    }

    @MainActor @Test func thePanelHearsTheWaitAndThenTheMeasuredGain() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let world = World()
        world.names = { $0 < 1 ? ["Deleting-1"] : [] }
        world.free = { _ in 170 }
        let runner = CleanupRunner(background: Self.waiter(world, audit: box.root.appending(path: "a.jsonl")))
        let texts = Texts()
        var report = CleanupExecutor.Report(freeBefore: 100, freeAfter: 120)
        await runner.waitForBackground(report) { texts.add($0) }
        #expect(texts.all.isEmpty)
        report.pending = [Self.device]
        await runner.waitForBackground(report) { texts.add($0) }
        #expect(texts.all == ["백그라운드에서 지우는 중 · 지금까지 +\(Int64(20).diskText)",
                              "실제로 늘어난 공간 +\(Int64(70).diskText) (삭제가 끝난 뒤 측정)"])
    }

    /// The next run cancels the wait; the cancelled wait then says nothing, or its last word would land on the new run's panel.
    @MainActor @Test func aWaitTheNextRunCancelsLeavesThatRunsPanelAlone() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        var dependencies = Self.waiter(World(), audit: box.root.appending(path: "a.jsonl")).dependencies
        dependencies.exists = { _ in true }
        dependencies.sleep = { try await Task.sleep(for: $0) }
        dependencies.interval = .seconds(60)
        let executor = fixtureExecutor(roots: [], audit: box.root.appending(path: "run.jsonl"))
        let runner = CleanupRunner(executor: executor, background: BackgroundDeletion(dependencies: dependencies))
        let texts = Texts()
        var report = CleanupExecutor.Report(freeBefore: 100, freeAfter: 120)
        report.pending = [Self.device]
        let first = Task { await runner.waitForBackground(report) { texts.add($0) } }
        try await Task.sleep(for: .milliseconds(100))
        _ = await runner.run([]) { _ in }
        await first.value
        #expect(texts.all == ["백그라운드에서 지우는 중 · 지금까지 +\(Int64(20).diskText)"])
    }

    // MARK: What the run saw

    final class Names: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [Set<String>?]
        private(set) var reads = 0
        init(_ answers: [Set<String>?]) { self.answers = answers }
        func next() -> Set<String>? { lock.withLock { reads += 1; return answers.isEmpty ? [] : answers.removeFirst() } }
    }

    static func simulatorRun(_ names: Names, udids: [String] = ["A", "B"]) async throws -> CleanupExecutor.Report {
        let box = try Sandbox()
        defer { box.remove() }
        let devices = udids.map { SimulatorList.Device(udid: $0, name: $0, runtime: "iOS 27.1", state: "Shutdown", dataPath: "/fake/\($0)/data",
                                                        dataBytes: 1, lastUsed: nil) }
        let executor = fixtureExecutor(roots: [], audit: box.root.appending(path: "audit.jsonl")) {
            $0.simulators = { devices }
            $0.deletingNames = { names.next() }
        }
        let rows = udids.map { udid in
            readyRow("simulator." + udid, [CleanupTarget(path: URL(fileURLWithPath: "/fake/\(udid)/data"), root: URL(fileURLWithPath: "/fake"),
                                                         identity: nil, action: .deleteSimulator(udid: udid))], trusted: false)
        }
        return await executor.run(rows) { _ in }
    }

    @Test func eachDeleteKeepsWhatAppearedRightAfterIt() async throws {
        // Before the run, after A, after B (A's trace still there).
        let report = try await Self.simulatorRun(Names([["Deleting-old"], ["Deleting-old", "Deleting-A"], ["Deleting-old", "Deleting-A", "Deleting-B"]]))
        #expect(report.pending == [.simulator(udid: "A", dataPath: "/fake/A/data", traces: ["Deleting-A"]),
                                   .simulator(udid: "B", dataPath: "/fake/B/data", traces: ["Deleting-B"])])
    }

    @Test func aBaselineThatCouldNotBeReadLeavesEveryTraceUnknown() async throws {
        let report = try await Self.simulatorRun(Names([nil, ["Deleting-A"], ["Deleting-A", "Deleting-B"]]))
        #expect(report.pending.allSatisfy { if case .simulator(_, _, nil) = $0 { true } else { false } } && report.pending.count == 2)
    }

    @Test func aRunWithoutSimulatorsNeverReadsTheTempFolder() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let names = Names([])
        let file = box.root.appending(path: "cache/a")
        try box.file("cache/a", bytes: 10)
        let executor = fixtureExecutor(roots: [box.root.appending(path: "cache")], audit: box.root.appending(path: "audit.jsonl")) {
            $0.deletingNames = { names.next() }
        }
        let row = readyRow("plain", [CleanupTarget(path: file, root: box.root.appending(path: "cache"), identity: FileIdentity.of(file.path),
                                                   action: .removeItem)], trusted: false)
        let report = await executor.run([row]) { _ in }
        #expect(report.deleted.count == 1 && report.pending.isEmpty && names.reads == 0)
    }
}
