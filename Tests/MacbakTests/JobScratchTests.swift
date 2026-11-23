import Foundation
import Testing
@testable import Macbak

/// Finished AI jobs' scratch folders on a sandbox home (`.claude/jobs`, `.claude/sessions`), judged by their grant. Every
/// file the judge reads goes through a spy, which must never see a session's `.key`.
@Suite struct JobScratchTests {
    final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [String] = []
        func add(_ url: URL) { lock.withLock { urls.append(url.lastPathComponent) } }
        var names: [String] { lock.withLock { urls } }
    }

    /// A job `id` in `state`, its state file and a 2 MB scratch file both `age` days old.
    @discardableResult
    static func job(_ box: Sandbox, _ id: String, state: String? = "done", age: Double = 10) throws -> URL {
        let folder = try box.folder(".claude/jobs/\(id)")
        try box.file(".claude/jobs/\(id)/tmp/work/out.bin", bytes: 2_000_000, modified: daysAgo(age))
        let json = state.map { #"{"state": "\#($0)"}"# } ?? "{}"
        try json.write(to: folder.appending(path: "state.json"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: daysAgo(age)], ofItemAtPath: folder.appending(path: "state.json").path)
        return folder.appending(path: "tmp")
    }

    static func sessions(_ box: Sandbox, pointingTo id: String? = nil) throws {
        try box.folder(".claude/sessions")
        try Data([1, 2, 3]).write(to: box.root.appending(path: ".claude/sessions/1234.abcd.key"))
        try #"{"pid": 1, "jobId": "\#(id ?? "other")"}"#.write(to: box.root.appending(path: ".claude/sessions/1234.json"), atomically: true, encoding: .utf8)
    }

    static func spying(_ reads: Reads) -> ProjectOutputScanner.Judge {
        { grant, inputs in
            var inputs = inputs
            inputs.read = { url in reads.add(url); return try? Data(contentsOf: url) }
            return TargetGrant.evaluate(grant, inputs)
        }
    }

    static func rows(_ box: Sandbox, open: [String] = [], reads: Reads = Reads()) -> [String: CleanupCandidate] {
        Dictionary(uniqueKeysWithValues: JobScratchScanner.scan(ProjectDiscoveryTests.context(box.root, open: open), judge: spying(reads))
            .map { ($0.targets[0].path.deletingLastPathComponent().lastPathComponent, $0) })
    }

    @Test func aFinishedQuietJobsScratchIsOfferedOnlyByHand() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let tmp = try Self.job(box, "done-old")
        try Self.sessions(box)
        let reads = Reads()
        let row = try #require(Self.rows(box, reads: reads)["done-old"])
        #expect(row.isSelectable && row.manualOnly && !row.isPreselected && !row.isShallow)
        #expect(row.targets.map(\.path.path) == [tmp.path] && row.targets[0].grant?.kind == .jobScratch)
        #expect(row.guards.watchPaths.map(\.path) == [tmp.deletingLastPathComponent().path])
        // The spy counts what the judge reads: the state file and the session's json, never its key.
        #expect(reads.names.contains("state.json") && reads.names.contains("1234.json"))
        #expect(!reads.names.contains { $0.hasSuffix(".key") })
    }

    @Test func aSessionFileThatCannotBeReadKeepsEveryJob() throws {
        let box = try Sandbox()
        defer { box.remove() }
        try Self.job(box, "done-old")
        try Self.sessions(box)
        try "{half written".write(to: box.root.appending(path: ".claude/sessions/5678.json"), atomically: true, encoding: .utf8)
        let row = try #require(Self.rows(box)["done-old"])
        #expect(!row.isSelectable && row.verdict.reason == "세션 기록을 읽지 못했습니다")
    }

    @Test func aJobNotDoneOrNotQuietIsNoCandidate() throws {
        let box = try Sandbox()
        defer { box.remove() }
        try Self.job(box, "working", state: "working")
        try Self.job(box, "blocked", state: "blocked")
        try Self.job(box, "unknown", state: nil)
        // Finished a day ago; its scratch files are older.
        try Self.job(box, "just-done")
        try FileManager.default.setAttributes([.modificationDate: daysAgo(1)], ofItemAtPath: box.root.appending(path: ".claude/jobs/just-done/state.json").path)
        try Self.job(box, "fresh-file")
        try box.file(".claude/jobs/fresh-file/tmp/new", modified: .now)
        try Self.sessions(box)
        #expect(Self.rows(box).values.filter(\.isSelectable).isEmpty)
    }

    @Test func anUnreadableEmptyNamedOrOpenScratchIsKept() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let locked = try Self.job(box, "locked")
        try box.file(".claude/jobs/locked/tmp/sealed/x", bytes: 10, modified: daysAgo(10))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.appending(path: "sealed").path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.appending(path: "sealed").path) }
        try Self.job(box, "named")
        let open = try Self.job(box, "open")
        try Self.sessions(box, pointingTo: "named")
        let rows = Self.rows(box, open: [open.appending(path: "work/out.bin").path])
        #expect(rows["locked"]?.verdict.reason == "다 훑지 못했습니다")
        #expect(rows["named"]?.verdict.reason == "살아 있는 세션이 이 작업을 가리킵니다")
        #expect(rows["open"]?.verdict.reason == "지금 쓰는 파일이 있습니다")

        let empty = try box.folder(".claude/jobs/empty/tmp")
        try #"{"state": "done"}"#.write(to: box.root.appending(path: ".claude/jobs/empty/state.json"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: daysAgo(10)], ofItemAtPath: box.root.appending(path: ".claude/jobs/empty/state.json").path)
        let inputs = TargetGrant.Inputs(now: .now, ages: CleanupAges(), open: OpenFiles.parse(lsofOutput([])), borrowers: [], reprove: false, home: box.root)
        #expect(TargetGrant.evaluate(TargetGrant(kind: .jobScratch, path: empty), inputs).refusal == "빈 임시 폴더입니다")
    }

    @Test func onlyExactlyAJobsScratchFolderIsGranted() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let tmp = try Self.job(box, "done-old")
        try Self.sessions(box)
        let inputs = TargetGrant.Inputs(now: .now, ages: CleanupAges(), open: OpenFiles.parse(lsofOutput([])), borrowers: [], reprove: false, home: box.root)
        #expect(TargetGrant.evaluate(TargetGrant(kind: .jobScratch, path: tmp), inputs).refusal == nil)
        let beside = try box.folder(".claude/jobs/done-old/out")
        for wrong in [tmp.appending(path: "work"), tmp.deletingLastPathComponent(), beside, box.root.appending(path: "elsewhere/done-old/tmp")] {
            #expect(TargetGrant.evaluate(TargetGrant(kind: .jobScratch, path: wrong), inputs).refusal == "AI 작업의 임시 폴더가 아닙니다")
        }
    }

    @Test func aChangeAfterTheScanStopsTheDeleteAndNoKeyIsRead() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        for id in ["new-file", "restarted", "resumed", "kept"] { try Self.job(box, id) }
        try Self.sessions(box)
        let rows = Self.rows(box).mapValues { row in var row = row; row.scannedAt = .now; return row }
        #expect(rows.count == 4 && rows.values.allSatisfy(\.isSelectable))
        try box.file(".claude/jobs/new-file/tmp/work/late", modified: .now)
        try #"{"state": "working"}"#.write(to: box.root.appending(path: ".claude/jobs/restarted/state.json"), atomically: true, encoding: .utf8)
        try #"{"pid": 2, "jobId": "resumed"}"#.write(to: box.root.appending(path: ".claude/sessions/5678.json"), atomically: true, encoding: .utf8)
        let reads = Reads()
        let executor = fixtureExecutor(roots: [], audit: box.root.appending(path: "audit.jsonl")) {
            $0.home = box.root
            $0.judgeGrant = Self.spying(reads)
        }
        let report = await executor.run(Array(rows.values)) { _ in }
        let outcomes = Dictionary(uniqueKeysWithValues: report.items.map { item in
            (rows.first { $0.value.id == item.id }!.key, item.outcome)
        })
        #expect(outcomes["new-file"] == .skipped("최근에 바뀐 파일이 있습니다"))
        #expect(outcomes["restarted"] == .skipped("끝난 작업이 아닙니다"))
        #expect(outcomes["resumed"] == .skipped("살아 있는 세션이 이 작업을 가리킵니다"))
        #expect(outcomes["kept"] == .deleted)
        #expect(reads.names.contains("state.json") && reads.names.contains("5678.json") && !reads.names.contains { $0.hasSuffix(".key") })
        #expect(FileManager.default.fileExists(atPath: box.root.appending(path: ".claude/sessions/1234.abcd.key").path))
    }

    @Test func theAIStorageRowStillOnlyShowsAndPointsToTheDiskScreen() throws {
        let box = try Sandbox()
        defer { box.remove() }
        try Self.job(box, "done-old")
        let report = AIStorageScanner.scan(running: [], openFiles: OpenFiles.parse(lsofOutput([])), home: box.root)
        let row = try #require(report.candidates.first { $0.id.hasSuffix(".jobs-finished") })
        #expect(row.targets.isEmpty && row.detail.contains("'프로젝트까지 검사'"))
    }
}
