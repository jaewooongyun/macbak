import Foundation
import Testing
@testable import Macbak

@Suite struct ManualOnlyTests {
    @Test func aManualOnlyRowIsNeverTickedNorShallowEvenWhenReadyAndTrusted() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let root = try box.folder("Caches")
        var row = readyRow("a", [ScanSupport.removal(try box.folder("Caches/a"), root: root)])
        #expect(row.isPreselected && row.isShallow)

        row.manualOnly = true
        #expect(row.verdict.status == .ready)
        #expect(row.isSelectable)
        #expect(!row.isPreselected)
        #expect(!row.isShallow)
    }

    @Test func newEvidenceKeepsTheMark() throws {
        var row = readyRow("a", [])
        row.manualOnly = true
        let changed = row.with(evidence: Evidence(verified: true, inUse: false, regenerable: true), aiEvidence: nil)
        #expect(changed.manualOnly)
    }

    @Test func aShallowRunDeletesNothingMarkedButADashboardRunDoes() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let root = try box.folder("Caches")
        try box.file("Caches/a/blob.bin")
        try box.file("Caches/b/blob.bin")
        var a = readyRow("a", [ScanSupport.removal(box.root.appending(path: "Caches/a"), root: root)])
        a.manualOnly = true
        let b = readyRow("b", [ScanSupport.removal(box.root.appending(path: "Caches/b"), root: root)])
        let executor = fixtureExecutor(roots: [root], audit: box.root.appending(path: "audit.jsonl"))
        let rows = [a, b]

        let shallow = await executor.run(rows, latest: { id in rows.first { $0.id == id } }, shallow: true) { _ in }
        #expect(shallow.items.map(\.outcome) == [.skipped("직접 골라야만 지우는 항목입니다"), .deleted])
        #expect(FileManager.default.fileExists(atPath: box.root.appending(path: "Caches/a/blob.bin").path))

        let picked = await executor.run([a]) { _ in }
        #expect(picked.items.map(\.outcome) == [.deleted])
        #expect(!FileManager.default.fileExists(atPath: box.root.appending(path: "Caches/a").path))
    }
}
