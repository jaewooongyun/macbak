import Darwin
import Foundation
import Testing
@testable import Macbak

/// Claude sessions idle past the Settings age: offered only when the session file, its process and every helper agree
/// it is idle, and ended with SIGTERM only after two fresh readings say the same.
@Suite struct AISessionTests {
    static let updated = Date(timeIntervalSince1970: 1_800_000_000)
    static let now = updated.addingTimeInterval(30 * 3600)
    static let procStart = Date(timeIntervalSince1970: 1_799_990_000)
    static let store = JobStore(root: ".claude/jobs")

    static func json(pid: Int = 200, status: String = "idle", kind: String = "bg", jobId: String? = "job1", updated: Date = updated,
                     procStart: Date = procStart, drop: String? = nil) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        var object: [String: Any] = ["pid": pid, "procStart": formatter.string(from: procStart), "status": status, "kind": kind,
                                     "updatedAt": Int(updated.timeIntervalSince1970 * 1000), "name": "a session", "cwd": "/somewhere"]
        if let jobId { object["jobId"] = jobId }
        if let drop { object[drop] = nil }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    static func record(_ data: Data = json()) -> AISessions.Record { AISessions.parse(data)! }

    static func entry(_ pid: pid_t, ppid: pid_t, name: String? = "node", start: Date? = updated.addingTimeInterval(-3600),
                      cpu: UInt64? = 1_000_000_000, footprint: UInt64 = 100) -> ProcessSnapshot.Entry {
        ProcessSnapshot.Entry(pid: pid, ppid: ppid, pgid: 200, uid: getuid(), path: "/opt/tool/\(name ?? "x")", name: name, start: start, footprint: footprint, cpu: cpu)
    }

    /// Root 200 (claude.exe) with helpers 201 and its child 202; the reading before is ten seconds earlier.
    static let root = entry(200, ppid: 1, name: "claude.exe", start: procStart.addingTimeInterval(0.4), cpu: 50_000_000_000, footprint: 1_000)
    static let tree = [root, entry(201, ppid: 200), entry(202, ppid: 201), entry(1, ppid: 0, name: "launchd")]

    static func table(_ entries: [ProcessSnapshot.Entry], at taken: Date) -> ProcessSnapshot {
        ProcessSnapshot(entries: Dictionary(uniqueKeysWithValues: entries.map { ($0.pid, $0) }), taken: taken)
    }

    static func inputs(records: [AISessions.Record] = [record()], now entries: [ProcessSnapshot.Entry] = tree,
                       before: [ProcessSnapshot.Entry]? = tree, window: TimeInterval = 10, states: [String: String] = ["job1": "done"],
                       idleAge: TimeInterval = 24 * 3600) -> AISessions.Inputs {
        AISessions.Inputs(records: records, snapshot: table(entries, at: now), previous: before.map { table($0, at: now.addingTimeInterval(-window)) },
                          jobStates: states, store: store, idleAge: idleAge, now: now, names: Set(AITool.claudeCode.process.names))
    }

    static func offered(_ inputs: AISessions.Inputs) -> [pid_t] { AISessions.candidates(inputs).map(\.id) }

    @Test func anIdleSessionWhoseJobIsDoneIsOfferedWithItsHelpers() throws {
        let session = try #require(AISessions.candidates(Self.inputs()).first)
        #expect(session.members == [200, 201, 202] && session.footprint == 1_200)
        #expect(session.helpers[202] == AISessions.Identity(start: Self.updated.addingTimeInterval(-3600), path: "/opt/tool/node"))
        // The root's own CPU does not count: an idle Claude process still ticks.
        #expect(Self.offered(Self.inputs(now: Self.tree.map { $0.pid == 200 ? Self.entry(200, ppid: 1, name: "claude.exe", start: Self.root.start, cpu: 90_000_000_000) : $0 })) == [200])
    }

    @Test func aSessionThatIsWorkingRecentOrNotProvablyItsOwnIsLeftAlone() {
        let reused = Self.tree.map { $0.pid == 200 ? Self.entry(200, ppid: 1, name: "claude.exe", start: Self.procStart.addingTimeInterval(7)) : $0 }
        let renamed = Self.tree.map { $0.pid == 200 ? Self.entry(200, ppid: 1, name: "node", start: Self.root.start) : $0 }
        let stranger = Self.tree.map { $0.pid == 200 ? ProcessSnapshot.Entry(pid: 200, ppid: 1, pgid: 200, uid: 0, name: "claude.exe", start: Self.root.start) : $0 }
        let cases: [(String, AISessions.Inputs)] = [
            ("busy", Self.inputs(records: [Self.record(Self.json(status: "busy"))])),
            ("recent", Self.inputs(records: [Self.record(Self.json(updated: Self.now.addingTimeInterval(-3600)))])),
            ("working job", Self.inputs(states: ["job1": "working"])),
            ("blocked job", Self.inputs(states: ["job1": "blocked"])),
            ("job unreadable", Self.inputs(states: [:])),
            ("bg without job", Self.inputs(records: [Self.record(Self.json(jobId: nil))])),
            ("pid gone", Self.inputs(now: Self.tree.filter { $0.pid != 200 })),
            ("pid reused", Self.inputs(now: reused)),
            ("not claude", Self.inputs(now: renamed)),
            ("another account", Self.inputs(now: stranger)),
            ("72 hours", Self.inputs(idleAge: 72 * 3600)),
        ]
        for (name, inputs) in cases { #expect(Self.offered(inputs).isEmpty, "\(name)") }
        // An interactive session is judged by the same rules without a job.
        #expect(Self.offered(Self.inputs(records: [Self.record(Self.json(kind: "interactive", jobId: nil))], states: [:])) == [200])
    }

    @Test func aFileThatDoesNotParseOrLacksAFieldIsNoSession() {
        #expect(AISessions.parse(Data("{not json".utf8)) == nil)
        for field in ["pid", "procStart", "status", "updatedAt", "kind", "name"] {
            #expect(AISessions.parse(Self.json(drop: field)) == nil, "\(field)")
        }
        #expect(AISessions.parse(Self.json(pid: 0)) == nil)
        #expect(AISessions.parseStart("Mon Nov  2 01:02:03 2026") != nil && AISessions.parseStart("2026-11-02") == nil)
        // A value read off a real session file and its process: UTC, whatever this Mac's zone (2026-11-23).
        #expect(AISessions.parseStart("Thu Nov 12 00:13:47 2026")?.timeIntervalSince1970 == 1_794_442_427)
    }

    @Test func aHelperThatWorksOrStartedLateOrCannotBeMeasuredProtectsTheSession() {
        let busy = Self.tree.map { $0.pid == 202 ? Self.entry(202, ppid: 201, cpu: 1_000_000_000 + 100_000_000) : $0 }
        let quiet = Self.tree.map { $0.pid == 202 ? Self.entry(202, ppid: 201, cpu: 1_000_000_000 + 90_000_000) : $0 }
        let late = Self.tree.map { $0.pid == 202 ? Self.entry(202, ppid: 201, start: Self.updated.addingTimeInterval(60)) : $0 }
        let noCPU = Self.tree.map { $0.pid == 202 ? Self.entry(202, ppid: 201, cpu: nil) : $0 }
        let noStart = Self.tree.map { $0.pid == 202 ? Self.entry(202, ppid: 201, start: nil) : $0 }
        #expect(Self.offered(Self.inputs(now: quiet)) == [200], "0.9% of the window is idle")
        // The start cells read the same start in both readings, so only their own check can refuse them.
        for (name, inputs) in [("1% of the window", Self.inputs(now: busy)), ("started after the last activity", Self.inputs(now: late, before: late)),
                               ("CPU unreadable", Self.inputs(now: noCPU)), ("start unreadable", Self.inputs(now: noStart, before: noStart)),
                               ("new since the reading before", Self.inputs(before: Self.tree.filter { $0.pid != 202 })),
                               ("first reading", Self.inputs(before: nil)), ("readings too close", Self.inputs(window: 4))] {
            #expect(Self.offered(inputs).isEmpty, "\(name)")
        }
    }

    @Test func anotherSessionRunningInsideTheTreeIsNotThisSessions() throws {
        let other = Self.record(Self.json(pid: 300, kind: "interactive", jobId: nil, updated: Self.now))
        let tree = Self.tree + [Self.entry(300, ppid: 201, name: "claude.exe", start: Self.procStart.addingTimeInterval(0.2)), Self.entry(301, ppid: 300)]
        let session = try #require(AISessions.candidates(Self.inputs(records: [Self.record(), other], now: tree, before: tree)).first)
        #expect(session.members == [200, 201, 202])
    }

    @Test func aStaleSessionWhosePidAHelperNowHoldsHidesNothing() {
        // Record 300's session has ended and pid 300 is now a busy node helper of session 200.
        let stale = Self.record(Self.json(pid: 300, kind: "interactive", jobId: nil))
        let before = Self.tree + [Self.entry(300, ppid: 201)]
        let now = Self.tree + [Self.entry(300, ppid: 201, cpu: 1_000_000_000 + 500_000_000)]
        #expect(Self.offered(Self.inputs(records: [Self.record(), stale], now: now, before: before)).isEmpty)
    }

    @Test func aProcessUnreadableWithoutHavingEndedLeavesTheTreeUnknown() {
        var hidden = Self.inputs()
        hidden.snapshot.unreadable = [4321]
        hidden.snapshot.hidden = [4321]
        #expect(Self.offered(hidden).isEmpty)
        // A zombie's children went to launchd as it exited: it hides nothing.
        var ended = Self.inputs()
        ended.snapshot.unreadable = [4321]
        #expect(Self.offered(ended) == [200])
    }

    @Test func onlyJsonFilesAreEverRead() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "sessions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Self.json().write(to: folder.appending(path: "a.json"))
        try Data("secret".utf8).write(to: folder.appending(path: "a.key"))
        try Data("{".utf8).write(to: folder.appending(path: "b.json"))
        let loaded = Box()
        let records = AISessions.read(folder.path) { path in
            loaded.add(path)
            return FileManager.default.contents(atPath: path)
        }
        #expect(records?.map(\.pid) == [200])
        #expect(loaded.all.map { ($0 as NSString).lastPathComponent }.sorted() == ["a.json", "b.json"])
        #expect(AISessions.read(folder.appending(path: "missing").path) == nil)
    }

    @Test func theDecisionNeverReadsProcessArguments() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/Macbak/System")
        for file in ["AISessions.swift", "OrphanProcesses.swift", "ProcessSnapshot.swift", "ProcessOwnership.swift"] {
            let text = try String(contentsOf: sources.appending(path: file), encoding: .utf8)
            #expect(!text.contains("ProcessArguments") && !text.contains("KERN_PROCARGS"), "\(file)")
        }
    }

    // MARK: Ending one

    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ item: String) { lock.withLock { items.append(item) } }
        var all: [String] { lock.withLock { items } }
    }

    final class Signals: @unchecked Sendable {
        private let lock = NSLock()
        private var sent: [String] = []
        func add(_ pid: pid_t, _ signal: Int32) { lock.withLock { sent.append("\(pid):\(signal)") } }
        var all: [String] { lock.withLock { sent } }
    }

    /// Reads `first` then `second` for the checks; after a signal, `after` gives each process-list read in turn (the last repeats).
    static func ending(first: AISessions.Inputs? = inputs(before: nil), second: AISessions.Inputs? = inputs(before: nil),
                       after: [[ProcessSnapshot.Entry]], signals: Signals, sent result: Int32 = 0) -> AISessions.Ending {
        let reads = Box()
        let lists = Box()
        return AISessions.Ending(
            read: {
                reads.add("r")
                return reads.all.count == 1 ? first.map { var i = $0; i.snapshot = table(tree, at: now.addingTimeInterval(-6)); return i } : second
            },
            snapshot: {
                lists.add("s")
                return table(after[min(lists.all.count, after.count) - 1], at: now)
            },
            signal: { pid, signal in
                signals.add(pid, signal)
                return result
            },
            sleep: { _ in })
    }

    static var session: IdleSession { AISessions.candidates(inputs()).first! }

    @Test func itEndsTheRootThenTheHelpersLeftBehindWithSIGTERMOnly() async {
        let signals = Signals()
        let orphaned = [Self.entry(201, ppid: 1), Self.entry(202, ppid: 201)]
        let outcome = await AISessions.end(Self.session, using: Self.ending(after: [orphaned, []], signals: signals))
        #expect(outcome == AISessions.Outcome(rootEnded: true, helpersEnded: 2, helpersLeft: 0) && outcome.reason == nil)
        #expect(Set(signals.all) == ["200:\(SIGTERM)", "201:\(SIGTERM)", "202:\(SIGTERM)"] && signals.all.first == "200:\(SIGTERM)")
    }

    @Test func aHelperNowUnderAnotherLiveSessionOrReplacedIsNotSignalled() async {
        let signals = Signals()
        let other = Self.record(Self.json(pid: 300, kind: "interactive", jobId: nil, updated: Self.now))
        var second = Self.inputs(before: nil)
        second.records.append(other)
        let after = [Self.entry(300, ppid: 1, name: "claude.exe", start: Self.procStart), Self.entry(202, ppid: 300),
                     Self.entry(201, ppid: 1, start: Self.updated)]
        let outcome = await AISessions.end(Self.session, using: Self.ending(second: second, after: [after], signals: signals))
        #expect(signals.all == ["200:\(SIGTERM)"])
        #expect(outcome == AISessions.Outcome(rootEnded: true, helpersEnded: 0, helpersLeft: 0))
    }

    @Test func aStaleRecordOnAHelpersPidDoesNotSpareTheHelpers() async {
        // Record 201's session ended long ago; pid 201 is this session's own helper, still with its start and path.
        let signals = Signals()
        var second = Self.inputs(before: nil)
        second.records.append(Self.record(Self.json(pid: 201, kind: "interactive", jobId: nil, updated: Self.now)))
        let left = [Self.entry(201, ppid: 1), Self.entry(202, ppid: 201)]
        let outcome = await AISessions.end(Self.session, using: Self.ending(second: second, after: [left, []], signals: signals))
        #expect(Set(signals.all) == ["200:\(SIGTERM)", "201:\(SIGTERM)", "202:\(SIGTERM)"])
        #expect(outcome == AISessions.Outcome(rootEnded: true, helpersEnded: 2, helpersLeft: 0))
    }

    @Test func aRootThatCannotBeSeenToEndSparesItsHelpers() async {
        var cut = Self.table([], at: Self.now)
        cut.truncated = true
        var hidden = Self.table([], at: Self.now)
        hidden.hidden = [200]
        var reusedInACutList = Self.table([Self.entry(200, ppid: 1, start: Self.now)], at: Self.now)
        reusedInACutList.truncated = true
        let afters = [("listed without a start", Self.table([Self.entry(200, ppid: 1, name: "claude.exe", start: nil)], at: Self.now)),
                      ("missing from a cut-short list", cut), ("hidden", hidden), ("another start in a cut-short list", reusedInACutList)]
        for (name, after) in afters {
            let signals = Signals()
            var ending = Self.ending(after: [[]], signals: signals)
            ending.snapshot = { after }
            let outcome = await AISessions.end(Self.session, using: ending)
            #expect(outcome == AISessions.Outcome() && signals.all == ["200:\(SIGTERM)"], "\(name)")
        }
    }

    @Test func aHelperThatCannotBeSeenToEndIsCountedAsLeft() async {
        let signals = Signals()
        let lists = Box()
        var ending = Self.ending(after: [[]], signals: signals)
        ending.snapshot = {
            lists.add("s")
            if lists.all.count == 1 { return Self.table([Self.entry(201, ppid: 1), Self.entry(202, ppid: 201)], at: Self.now) }
            var cut = Self.table([], at: Self.now)
            cut.truncated = true
            return cut
        }
        let outcome = await AISessions.end(Self.session, using: ending)
        #expect(outcome == AISessions.Outcome(rootEnded: true, helpersEnded: 0, helpersLeft: 2))
    }

    @Test func anotherSessionThatCannotBeReadKeepsEveryHelper() async {
        var second = Self.inputs(before: nil)
        second.records.append(Self.record(Self.json(pid: 300, kind: "interactive", jobId: nil, updated: Self.now)))
        var hidden = Self.table([Self.entry(202, ppid: 1), Self.entry(201, ppid: 1)], at: Self.now)
        hidden.hidden = [300]
        let unreadable = Self.table([Self.entry(300, ppid: 1, name: "claude.exe", start: nil), Self.entry(202, ppid: 300), Self.entry(201, ppid: 1)], at: Self.now)
        for (name, after) in [("its root listed without a start", unreadable), ("its root hidden", hidden)] {
            let signals = Signals()
            var ending = Self.ending(second: second, after: [[]], signals: signals)
            ending.snapshot = { after }
            let outcome = await AISessions.end(Self.session, using: ending)
            #expect(signals.all == ["200:\(SIGTERM)"] && outcome == AISessions.Outcome(rootEnded: true, helpersLeft: 2), "\(name)")
        }
    }

    @Test func aHelperUnreadableRightAfterTheRootEndsIsCountedAsLeft() async {
        let signals = Signals()
        let lists = Box()
        var ending = Self.ending(after: [[]], signals: signals)
        ending.snapshot = {
            lists.add("s")
            guard lists.all.count == 1 else { return Self.table([], at: Self.now) }
            var first = Self.table([Self.entry(202, ppid: 1)], at: Self.now)
            first.hidden = [201]
            return first
        }
        let outcome = await AISessions.end(Self.session, using: ending)
        #expect(signals.all == ["200:\(SIGTERM)", "202:\(SIGTERM)"])
        #expect(outcome == AISessions.Outcome(rootEnded: true, helpersEnded: 1, helpersLeft: 1))
    }

    @Test func aHelperNowRunningAnotherProgramIsNotSignalled() async {
        let signals = Signals()
        // Pid 201 keeps its start but runs another program now: no longer the helper that was found idle.
        let after = [Self.entry(201, ppid: 1, name: "python3"), Self.entry(202, ppid: 1)]
        let outcome = await AISessions.end(Self.session, using: Self.ending(after: [after, []], signals: signals))
        #expect(Set(signals.all) == ["200:\(SIGTERM)", "202:\(SIGTERM)"])
        #expect(outcome == AISessions.Outcome(rootEnded: true, helpersEnded: 1, helpersLeft: 1))
    }

    @Test func whatDidNotEndIsReported() async {
        let stubborn = Signals()
        let one = [Self.entry(201, ppid: 1), Self.entry(202, ppid: 201)]
        let partly = await AISessions.end(Self.session, using: Self.ending(after: [one, [Self.entry(202, ppid: 1)]], signals: stubborn))
        #expect(partly.reason == "남은 보조 1개 끝냄 · 1개 끝나지 않음")

        let rootStays = Signals()
        let stays = await AISessions.end(Self.session, using: Self.ending(after: [Self.tree], signals: rootStays))
        #expect(stays.reason == "세션이 끝나지 않음" && rootStays.all == ["200:\(SIGTERM)"])
    }

    @Test func aCancelledRunSignalsNothing() async {
        let signals = Signals()
        var ending = Self.ending(after: [[]], signals: signals)
        ending.sleep = { _ in throw CancellationError() }
        #expect(await AISessions.end(Self.session, using: ending) == AISessions.Outcome(refused: "취소됨") && signals.all.isEmpty)
    }

    @Test func aSessionThatChangedBeforeTheSignalIsNotSignalled() async {
        let changes: [(String, AISessions.Inputs?)] = [
            ("updated", Self.inputs(records: [Self.record(Self.json(updated: Self.updated.addingTimeInterval(1)))], before: nil)),
            ("busy", Self.inputs(records: [Self.record(Self.json(status: "busy"))], before: nil)),
            ("job working", Self.inputs(before: nil, states: ["job1": "blocked"])),
            ("restarted", Self.inputs(now: Self.tree.map { $0.pid == 200 ? Self.entry(200, ppid: 1, name: "claude.exe", start: Self.procStart.addingTimeInterval(9)) : $0 }, before: nil)),
            ("other binary", Self.inputs(now: Self.tree.map { $0.pid == 200 ? Self.entry(200, ppid: 1, name: "bash", start: Self.root.start) : $0 }, before: nil)),
            ("gone", Self.inputs(now: Self.tree.filter { $0.pid != 200 }, before: nil)),
            ("file gone", Self.inputs(records: [], before: nil)),
            ("helper busy", Self.inputs(now: Self.tree.map { $0.pid == 201 ? Self.entry(201, ppid: 200, cpu: 9_000_000_000) : $0 }, before: nil)),
            ("unreadable", nil),
        ]
        for (name, second) in changes {
            let signals = Signals()
            let outcome = await AISessions.end(Self.session, using: Self.ending(second: second, after: [[]], signals: signals))
            #expect(outcome.refused != nil && signals.all.isEmpty, "\(name)")
        }
    }
}
