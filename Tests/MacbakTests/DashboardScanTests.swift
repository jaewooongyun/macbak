import Foundation
import Testing
@testable import Macbak

/// The dashboard's scan: the usual and the expanded scan together, each result kept while fresh, an expanded scan in
/// progress joined and looked at again, and both registered at once so a run never starts between them.
/// The usual scans are counted by Xcode's area, the expanded ones by the walk.
@Suite struct DashboardScanTests {
    typealias P = ProjectDiscoveryTests

    struct Rig {
        let box: Sandbox
        let counts: P.Counts
        let settings: CleanupSettings
        let coordinator: CleanupCoordinator
        var usual: Int { counts.of("xcode") }
        var walks: Int { counts.of("walk") }
    }

    /// Settings held in memory only, so no test leaves a preferences file behind.
    @MainActor static func rig(usual: P.Hold = P.Hold(), walk: P.Hold = P.Hold(),
                               listed: [CleanupCoordinator.Area: [CleanupCandidate]] = [:]) throws -> Rig {
        let box = try Sandbox()
        let counts = P.Counts()
        let settings = CleanupSettings(defaults: nil)
        let coordinator = P.coordinator(box.root, counts: counts, memory: BorrowerMemory(url: box.root.appending(path: "b.json")),
                                        settings: settings, usual: usual, walk: walk, listed: listed)
        return Rig(box: box, counts: counts, settings: settings, coordinator: coordinator)
    }

    @MainActor @Test func theFirstCallRunsBothScans() async throws {
        let r = try Self.rig()
        defer { r.box.remove() }
        await r.coordinator.scanEverything()
        #expect(r.usual == 1 && r.walks == 1)
        #expect(!r.coordinator.isStale && !r.coordinator.isProjectsStale)
    }

    @MainActor @Test func aCallWhileBothAreFreshScansNothing() async throws {
        let r = try Self.rig()
        defer { r.box.remove() }
        await r.coordinator.scanEverything()
        await r.coordinator.scanEverything()
        #expect(r.usual == 1 && r.walks == 1)
    }

    @MainActor @Test func forceScansBothAgain() async throws {
        let r = try Self.rig()
        defer { r.box.remove() }
        await r.coordinator.scanEverything()
        await r.coordinator.scanEverything(force: true)
        #expect(r.usual == 2 && r.walks == 2)
    }

    @MainActor @Test func afterTheUsualScanAloneBothRun() async throws {
        let r = try Self.rig()
        defer { r.box.remove() }
        await r.coordinator.scan()
        await r.coordinator.scanEverything()
        #expect(r.usual == 2 && r.walks == 1)
    }

    @MainActor @Test func afterTheExpandedScanAloneBothRun() async throws {
        let r = try Self.rig()
        defer { r.box.remove() }
        await r.coordinator.scanProjects()
        await r.coordinator.scanEverything()
        #expect(r.usual == 1 && r.walks == 2)
    }

    @MainActor @Test func twoCallsAtOnceShareOneScan() async throws {
        let walk = P.Hold(shut: true)
        let r = try Self.rig(walk: walk)
        defer { r.box.remove() }
        let first = Task { await r.coordinator.scanEverything() }
        try await P.until { walk.held > 0 }
        let second = Task { await r.coordinator.scanEverything() }
        await Task.yield()
        walk.open()
        await first.value
        await second.value
        #expect(r.usual == 1 && r.walks == 1)
    }

    /// The walk ends while the usual scan still runs: the call that joined the walk does not start another one.
    @MainActor @Test func aCallThatJoinedWaitsForTheUsualScanBeforeLookingAgain() async throws {
        let usual = P.Hold(shut: true), walk = P.Hold(shut: true)
        let r = try Self.rig(usual: usual, walk: walk)
        defer { r.box.remove() }
        let first = Task { await r.coordinator.scanEverything() }
        try await P.until { walk.held > 0 && usual.held > 0 }
        let second = Task { await r.coordinator.scanEverything() }
        await Task.yield()
        walk.open()
        try await P.until { r.coordinator.projectsScannedAt != nil }
        try await Task.sleep(for: .milliseconds(200))
        usual.open()
        await first.value
        await second.value
        #expect(r.usual == 1 && r.walks == 1)
    }

    /// The walk has ended and only the usual scan still runs: a new call waits for it instead of walking again.
    @MainActor @Test func aCallAfterTheWalkEndedWaitsForTheUsualScan() async throws {
        let usual = P.Hold(shut: true)
        let r = try Self.rig(usual: usual)
        defer { r.box.remove() }
        let first = Task { await r.coordinator.scanEverything() }
        try await P.until { r.coordinator.projectsScannedAt != nil }
        let second = Task { await r.coordinator.scanEverything() }
        try await Task.sleep(for: .milliseconds(200))
        usual.open()
        await first.value
        await second.value
        #expect(r.usual == 1 && r.walks == 1)
    }

    /// Settings changed while the walk is held: the call that joined it scans again by the new ages.
    @MainActor @Test func aCallThatJoinedLooksAgainAfterSettingsChanged() async throws {
        let walk = P.Hold(shut: true)
        let r = try Self.rig(walk: walk)
        defer { r.box.remove() }
        let first = Task { await r.coordinator.scanEverything() }
        try await P.until { walk.held > 0 && r.coordinator.scannedAt != nil }
        r.settings.set(.buildCache, 3)
        let second = Task { await r.coordinator.scanEverything() }
        await Task.yield()
        walk.open()
        await first.value
        await second.value
        #expect(r.usual == 2 && r.walks == 2)
        #expect(!r.coordinator.isStale && !r.coordinator.isProjectsStale)
    }

    @MainActor @Test func resultsAgeByTheInjectedClock() async throws {
        let r = try Self.rig()
        defer { r.box.remove() }
        await r.coordinator.scanEverything()
        // From the scans' own start times, which a busy machine puts seconds before the call returns.
        let usualAt = try #require(r.coordinator.scannedAt), expandedAt = try #require(r.coordinator.projectsScannedAt)
        let earlier = min(usualAt, expandedAt), later = max(usualAt, expandedAt)
        r.coordinator.now = { earlier.addingTimeInterval(599) }
        await r.coordinator.scanEverything()
        #expect(r.usual == 1 && r.walks == 1)
        r.coordinator.now = { later.addingTimeInterval(601) }
        await r.coordinator.scanEverything()
        #expect(r.usual == 2 && r.walks == 2)
    }

    /// The fast expanded areas show while the walk still runs.
    @MainActor @Test func runtimesAndJobsShowWhileTheWalkRuns() async throws {
        let walk = P.Hold(shut: true)
        let r = try Self.rig(walk: walk, listed: [.runtimes: [ScanReportTests.row("runtime.a")], .jobs: [ScanReportTests.row("jobs.a")]])
        defer { r.box.remove() }
        let scanning = Task { await r.coordinator.scanEverything() }
        try await P.until { walk.held > 0 && r.coordinator.scannedAt != nil && r.coordinator.candidates[.jobs] != nil }
        try await P.until { r.coordinator.candidates[.runtimes] != nil }
        #expect(r.coordinator.candidates[.runtimes]?.map(\.id) == ["runtime.a"] && r.coordinator.candidates[.jobs]?.map(\.id) == ["jobs.a"])
        #expect(r.coordinator.scanning == [.projects])
        walk.open()
        await scanning.value
    }

    @MainActor @Test func aFixtureNeverScans() async {
        let coordinator = CleanupCoordinator(fixture: [.appCaches: [ScanReportTests.row("a")]])
        #expect(!coordinator.isStale && !coordinator.isProjectsStale)
        await coordinator.scanEverything(force: true)
        #expect(coordinator.candidates[.appCaches]?.map(\.id) == ["a"] && coordinator.projectsScannedAt == nil)
    }

    @MainActor @Test func theExpandedResultIsStaleBeforeAScanAndAfterSettingsChange() async throws {
        let r = try Self.rig()
        defer { r.box.remove() }
        #expect(r.coordinator.isProjectsStale)
        await r.coordinator.scanEverything()
        #expect(!r.coordinator.isProjectsStale)
        r.settings.set(.buildCache, 3)
        #expect(r.coordinator.isProjectsStale)
    }

    /// A run started one turn after the dashboard's scan waits for both scans, not only the usual one, before deleting.
    @MainActor @Test func aRunStartedRightAfterWaitsForBothScans() async throws {
        let usual = P.Hold(shut: true), walk = P.Hold(shut: true)
        let r = try Self.rig(usual: usual, walk: walk)
        defer { r.box.remove() }
        let caches = try r.box.folder("Caches")
        try r.box.file("Caches/l/blob.bin")
        let folder = r.box.root.appending(path: "Caches/l")
        let runner = CleanupRunner(executor: fixtureExecutor(roots: [caches], audit: r.box.root.appending(path: "audit.jsonl")),
                                   settle: { await r.coordinator.settled() })
        r.coordinator.isDeleting = { [weak runner] in runner?.isRunning ?? false }

        let scanning = Task { await r.coordinator.scanEverything() }
        await Task.yield()
        let run = Task { await runner.run([readyRow("l", [ScanSupport.removal(folder, root: caches)])]) { _ in } }
        try await P.until { usual.held > 0 }
        usual.open()
        try await P.until { r.coordinator.scannedAt != nil }
        try await Task.sleep(for: .milliseconds(300))
        #expect(FileManager.default.fileExists(atPath: folder.path))

        walk.open()
        let report = await run.value
        #expect(report.deleted.map(\.id) == ["l"] && !FileManager.default.fileExists(atPath: folder.path))
        #expect(r.coordinator.projectsScannedAt != nil)
        await scanning.value
    }
}
