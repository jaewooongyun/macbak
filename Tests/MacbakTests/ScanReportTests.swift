import Darwin
import Foundation
import Testing
@testable import Macbak

/// `--scan-report`'s lines for the expanded areas: every area and state named, counts only, and
/// nothing in the report path able to delete or end anything.
@Suite struct ScanReportTests {
    static func row(_ id: String, selectable: Bool = true) -> CleanupCandidate {
        let target = CleanupTarget(path: URL(fileURLWithPath: "/tmp/\(id)"), root: URL(fileURLWithPath: "/tmp"), identity: nil, action: .removeItem)
        return CleanupCandidate(id: id, name: "secret-name-\(id)", detail: "", symbol: "folder", bytes: 1,
                                evidence: Evidence(verified: true, inUse: !selectable, regenerable: true), targets: [target], scannedAt: .now)
    }

    static func summary(memory: BorrowerMemory.State = .none, partial: Bool = false) -> ScanReport.Summary {
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
            discovery: found, standardCaches: 3, memory: memory, lifts: 4)
    }

    @Test func everyExpandedAreaAndStateHasALine() {
        let text = ScanReport.lines(Self.summary()).joined(separator: "\n")
        for line in ["시뮬레이터 런타임: 2줄 · 고를 수 있음 1", "프로젝트 · Xcode 빌드 캐시: 1줄 · 고를 수 있음 1",
                     "프로젝트 · git 이 무시하는 빌드 산출물: 2줄 · 고를 수 있음 1", "프로젝트 · node_modules: 1줄 · 고를 수 있음 1",
                     "끝난 AI 작업 임시 파일: 1줄 · 고를 수 있음 1", "확장 탐색: 폴더 1234개 · 끝까지 탐색",
                     "검사하지 않은 곳: Library · git 목록을 못 읽은 프로젝트 1곳", "차용 지도 범위: 표준 빌드 캐시 3곳 + 찾은 빌드 캐시 2곳",
                     "차용 기억: 없음", "다시 증명한 보통 줄: 4개"] {
            #expect(text.contains(line), "\(line)")
        }
        #expect(!text.contains("secret-name") && !text.contains("/r/") && !text.contains("/x/"))
    }

    @Test func partialWalksAndBorrowerMemoryStatesAreNamed() {
        #expect(ScanReport.lines(Self.summary(partial: true)).contains("확장 탐색: 폴더 1234개 · 부분 탐색(예산 소진)"))
        #expect(ScanReport.lines(Self.summary(memory: .corrupt)).contains("차용 기억: 손상"))
        let edge = BorrowerMemory.Edge(lender: "/a", borrower: "/b")
        #expect(ScanReport.lines(Self.summary(memory: .edges([edge]))).contains("차용 기억: 정상 · 연결 1개"))
    }

    @Test func theReportPathCannotDeleteOrEndAnything() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/Macbak/App/ScanReport.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        for call in ["kill(", "executor.run(", "removeItem(at", "AppQuitter", "SimulatorShutdown", "BackgroundDeletion"] {
            #expect(!text.contains(call), "\(call)")
        }
        #expect(text.contains("preflight("))
    }
}
