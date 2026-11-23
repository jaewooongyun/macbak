import SwiftUI
import Testing
@testable import Macbak

/// A run that waits for a scan in progress says so, and only until it starts deleting.
@MainActor
@Suite struct RunSettlingTests {
    /// A settle the test lets go of.
    @MainActor final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        var waiting: Bool { continuation != nil }
        func wait() async { await withCheckedContinuation { continuation = $0 } }
        func open() {
            continuation?.resume()
            continuation = nil
        }
    }

    @MainActor final class Seen {
        var list: [String] = []
    }

    @Test func aRunWaitingForAScanSaysSoUntilItDeletes() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let root = try box.folder("Caches")
        try box.file("Caches/a/blob.bin")
        let row = readyRow("a", [ScanSupport.removal(box.root.appending(path: "Caches/a"), root: root)])
        let gate = Gate()
        let runner = CleanupRunner(executor: fixtureExecutor(roots: [root], audit: box.root.appending(path: "audit.jsonl")), settle: { await gate.wait() })
        let seen = Seen()
        let run = Task { await runner.run([row]) { _ in seen.list.append("running \(runner.isRunning) settling \(runner.isSettling)") } }
        try await ProjectDiscoveryTests.until { gate.waiting }
        #expect(runner.isRunning && runner.isSettling)

        // Refused while the first run waits, and the flag stays the first run's.
        let refused = await runner.run([row]) { _ in }
        #expect(refused.refusal == "이미 정리하는 중입니다." && runner.isSettling)

        gate.open()
        let report = await run.value
        #expect(report.deleted.map(\.id) == ["a"] && !runner.isSettling && !runner.isRunning)
        #expect(seen.list == ["running true settling false"])
    }

    @Test func thePanelSaysItWaitsOnlyWhileItWaits() {
        #expect(CleanupBoard<EmptyView>.wording(settling: true).running == "진행 중인 검사가 끝나면 지웁니다")
        #expect(CleanupBoard<EmptyView>.wording(settling: false).running == RunWording.cleanup.running)
    }
}
