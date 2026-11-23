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

    /// A ticked, trusted row is still out of the shallow clean-up when a grant or a runtime delete is among its targets,
    /// and a shallow run deletes nothing of it.
    @Test func aGrantedFolderOrARuntimeIsNeverShallow() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let root = try box.folder("Caches")
        try box.file("Caches/g/blob.bin")
        let folder = box.root.appending(path: "Caches/g")
        let plain = ScanSupport.removal(folder, root: root)
        #expect(readyRow("g", [plain]).isShallow)
        let granted = CleanupTarget(path: folder, root: root, identity: plain.identity, action: .removeItem,
                                    grant: TargetGrant(kind: .derivedData, path: folder))
        let row = readyRow("g", [granted])
        #expect(row.trusted && !row.manualOnly && row.isPreselected && !row.isShallow)
        let runtime = CleanupTarget(path: folder, root: root, identity: nil, action: .deleteRuntime(identifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-0"))
        #expect(!readyRow("r", [runtime]).isShallow)

        let executor = fixtureExecutor(roots: [root], audit: box.root.appending(path: "audit.jsonl"))
        let report = await executor.run([row], latest: { _ in row }, shallow: true) { _ in }
        #expect(report.deleted.isEmpty && FileManager.default.fileExists(atPath: folder.appending(path: "blob.bin").path))
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
