import Darwin
import Foundation
import Testing
@testable import Macbak

/// `--scan-report`'s lines for the expanded areas and the memory side: every area and state named, counts only, and
/// nothing in the report path able to delete or end anything.
@Suite struct ScanReportTests {
    static func row(_ id: String, selectable: Bool = true) -> CleanupCandidate {
        let target = CleanupTarget(path: URL(fileURLWithPath: "/tmp/\(id)"), root: URL(fileURLWithPath: "/tmp"), identity: nil, action: .removeItem)
        return CleanupCandidate(id: id, name: "secret-name-\(id)", detail: "", symbol: "folder", bytes: 1,
                                evidence: Evidence(verified: true, inUse: !selectable, regenerable: true), targets: [target], scannedAt: .now)
    }

    static func summary(memory: BorrowerMemory.State = .none, partial: Bool = false,
                        processes: ScanReport.Summary.Processes? = .init(helpersSummed: true, orphans: 2, idleSessions: 1)) -> ScanReport.Summary {
        var found = ProjectDiscovery.Result()
        found.partial = partial
        found.visited = 1234
        found.derivedData = [URL(fileURLWithPath: "/x/a"), URL(fileURLWithPath: "/x/b")]
        found.skipped = ["Library", "git 목록을 못 읽은 프로젝트 1곳"]
        return ScanReport.Summary(
            runtimes: [row("runtime.a"), row("runtime.b", selectable: false)],
            projects: [row("project.derivedData./x/a"), row("project.artifact./r/build"), row("project.artifact./r/target", selectable: false),
                       row("project.nodeModules./r/web/node_modules")],
            jobs: [row("jobs./j/1/tmp")],
            discovery: found, standardCaches: 3, memory: memory, lifts: 4, processes: processes)
    }

    /// What the 2026-11-24 work added: rows nothing could tell, the person's rules, the disk summary and who picked it,
    /// the answers for the folders asked about (no rule saved), and the virtual machines on the memory side.
    @Test func theReportShowsWhatIsNewInOneLineEach() {
        func kept(_ id: String, _ bytes: Int64, _ reason: String, ask: Bool) -> CleanupCandidate {
            var evidence = Evidence()
            evidence.protectedReason = reason
            var row = CleanupCandidate(id: id, name: id, detail: "", symbol: "folder", bytes: bytes, evidence: evidence)
            if ask { row.askInput = ExploreInput(url: URL(fileURLWithPath: "/x/\(id)"), relative: id, inside: "", beside: "") }
            return row
        }
        let rows = [kept("u1", 2_000_000_000, CacheRules.unsureReason, ask: true), kept("u2", 1_000_000_000, CacheRules.modelUnsureReason, ask: false),
                    kept("k", 5_000_000_000, "보호", ask: false), Self.row("r")]
        let template = DiskNarrator.Narration(headline: .roomy, facts: [], byModel: false)
        let lines = ScanReport.generalLines(rows: rows, rules: .rules(["a", "b"]), narration: template,
                                            asked: [("u1", .proposal(evidence: "hash-named files")), ("x", .kept(evidence: "documents")),
                                                    ("y", .unsure(reason: "기기 AI도 판단하지 못했습니다.")), ("z", nil)])
        #expect(lines == [
            "근거 부족: 2줄 · 3 GB · 기기 AI에게 물을 수 있음 1줄",
            "사용자 규칙: 2개",
            "디스크 요약(템플릿): 사용 가능 공간은 아직 넉넉합니다.",
            "묻기 결과(규칙은 저장하지 않음): 4줄",
            "  u1\t제안\thash-named files", "  x\t지킴\tdocuments", "  y\t판단 못 함\t기기 AI도 판단하지 못했습니다.", "  z\t답 없음(시간 초과)",
        ])
        let picked = DiskNarrator.Narration(headline: .tight, facts: [.init(id: .ready, text: "지워도 되는 것 1개, 2 GB", prompt: "", weight: 1)], byModel: true)
        let other = ScanReport.generalLines(rows: [], rules: .unreadable, narration: picked, asked: [])
        #expect(other.contains("사용자 규칙: 파일을 읽을 수 없음(규칙 없이 판정)"))
        #expect(other.contains("디스크 요약(기기 AI가 고름): 사용 가능 공간이 부족합니다. / 지워도 되는 것 1개, 2 GB"))
        #expect(ScanReport.generalLines(rows: [], rules: .none, narration: nil, asked: [("w", .unavailable(reason: "모델 없음 사유"))]).last == "  w\t모델 없음\t모델 없음 사유")
        let none = ScanReport.generalLines(rows: [], rules: .none, narration: nil, asked: [])
        #expect(none.contains("사용자 규칙: 없음") && none.contains("디스크 요약: 디스크를 읽지 못함"))
        let machines = ScanReport.lines(Self.summary(processes: .init(helpersSummed: true, orphans: 2, idleSessions: 1, machines: 3)))
        #expect(machines.contains { $0.hasPrefix("메모리 쪽:") && $0.hasSuffix(" · 가상 머신·에뮬레이터 3개") })
    }

    @Test func everyExpandedAreaAndStateHasALine() {
        let text = ScanReport.lines(Self.summary()).joined(separator: "\n")
        for line in ["시뮬레이터 런타임: 2줄 · 고를 수 있음 1", "프로젝트 · Xcode 빌드 캐시: 1줄 · 고를 수 있음 1",
                     "프로젝트 · git 이 무시하는 빌드 산출물: 2줄 · 고를 수 있음 1", "프로젝트 · node_modules: 1줄 · 고를 수 있음 1",
                     "끝난 AI 작업 임시 파일: 1줄 · 고를 수 있음 1", "확장 탐색: 폴더 1234개 · 끝까지 탐색",
                     "검사하지 않은 곳: Library · git 목록을 못 읽은 프로젝트 1곳", "차용 지도 범위: 표준 빌드 캐시 3곳 + 찾은 빌드 캐시 2곳",
                     "차용 기억: 없음", "다시 증명한 보통 줄: 4개",
                     "메모리 쪽: 보조 프로세스 합산 가능 · 주인 없는 개발 도구 2개 · 오래 쉬는 AI 세션 1개 · 가상 머신·에뮬레이터 0개"] {
            #expect(text.contains(line), "\(line)")
        }
        #expect(!text.contains("secret-name") && !text.contains("/r/") && !text.contains("/x/"))
    }

    @Test func partialWalksBorrowerMemoryStatesAndAnUnreadMemorySideAreNamed() {
        #expect(ScanReport.lines(Self.summary(partial: true)).contains("확장 탐색: 폴더 1234개 · 부분 탐색(예산 소진)"))
        #expect(ScanReport.lines(Self.summary(memory: .corrupt)).contains("차용 기억: 손상"))
        let edge = BorrowerMemory.Edge(lender: "/a", borrower: "/b")
        #expect(ScanReport.lines(Self.summary(memory: .edges([edge]))).contains("차용 기억: 정상 · 연결 1개"))
        #expect(ScanReport.lines(Self.summary(processes: nil)).contains("메모리 쪽: 프로세스 목록을 읽지 못함"))
        let unread = ScanReport.Summary.Processes(helpersSummed: false, orphans: 0, idleSessions: nil)
        #expect(ScanReport.lines(Self.summary(processes: unread)).contains("메모리 쪽: 보조 프로세스 합산 불가 · 주인 없는 개발 도구 0개 · 오래 쉬는 AI 세션 읽지 못함 · 가상 머신·에뮬레이터 0개"))
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func add() { lock.withLock { count += 1 } }
        var total: Int { lock.withLock { count } }
    }

    @Test func theMemorySideReadsTwiceAndCountsWhatTheScreenWouldOffer() {
        let reads = Counter()
        let between = Counter()
        let home = NSHomeDirectory()
        let start = Date(timeIntervalSince1970: Date.now.addingTimeInterval(-3600).timeIntervalSince1970.rounded(.down))
        let entries = [
            ProcessSnapshot.Entry(pid: 999_999, ppid: 1, pgid: 999_998, uid: getuid(), path: home + "/.bun/bin/bun", start: start, footprint: 1, cpu: 0),
            ProcessSnapshot.Entry(pid: 999_990, ppid: 1, pgid: 999_990, uid: getuid(), name: "claude", start: start, footprint: 1, cpu: 0),
        ]
        let record = AISessions.Record(pid: 999_990, procStart: start, status: "idle", updatedAt: .now.addingTimeInterval(-48 * 3600), kind: "interactive", jobId: nil, name: "s")
        let sources = SystemMonitor.ProcessSources(
            snapshot: {
                reads.add()
                return ProcessSnapshot(entries: Dictionary(uniqueKeysWithValues: entries.map { ($0.pid, $0) }), taken: .now.addingTimeInterval(Double(reads.total) * 10))
            },
            responsible: nil, services: { [] }, sessions: { [record] }, jobStates: { _ in [:] })
        let side = ScanReport.processes(sources, apps: [:], idleAge: 24 * 3600) { between.add() }
        #expect(reads.total == 2 && between.total == 1)
        #expect(side == ScanReport.Summary.Processes(helpersSummed: false, orphans: 1, idleSessions: 1))
    }

    @Test func aListedRowSaysWhetherItIsTickedOrReproven() {
        let ticked = Self.row("a")
        #expect(ticked.isPreselected && ScanReport.rowLine(ticked).hasSuffix("\t미리 체크"))
        var reproven = Self.row("b")
        reproven.manualOnly = true
        reproven.reproved = true
        #expect(ScanReport.rowLine(reproven).hasSuffix("\t다시 증명") && !ScanReport.rowLine(reproven).contains("미리 체크"))
        var chosen = Self.row("c")
        chosen.manualOnly = true
        #expect(!ScanReport.rowLine(chosen).contains("미리 체크") && !ScanReport.rowLine(chosen).contains("다시 증명"))
    }

    @Test func theReportPathCannotDeleteOrEndAnything() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/Macbak/App/ScanReport.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        for call in ["kill(", "OrphanProcesses.end", "AISessions.end", "executor.run(", "removeItem(at", "AppQuitter", "SimulatorShutdown", "BackgroundDeletion"] {
            #expect(!text.contains(call), "\(call)")
        }
        #expect(text.contains("preflight("))
    }
}
