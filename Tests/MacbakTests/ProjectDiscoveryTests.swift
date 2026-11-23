import Foundation
import Testing
@testable import Macbak

/// The expanded scan on a sandbox home: the walk for build caches outside the usual places, their rows and grant, the
/// coordinator's separate state, and the re-proof that lifts a usual row's alarm, end to end with real git checkouts.
@Suite struct ProjectDiscoveryTests {
    /// A folder shaped like an Xcode build cache, its files `age` days old.
    @discardableResult
    static func derivedData(_ box: Sandbox, _ path: String, age: Double = 2) throws -> URL {
        try box.file(path + "/Build/blob", bytes: 2_000_000, modified: daysAgo(age))
        let plist = try PropertyListSerialization.data(fromPropertyList: ["WorkspacePath": "/nonexistent/App/App.xcodeproj"], format: .xml, options: 0)
        try plist.write(to: box.root.appending(path: path + "/info.plist"))
        try FileManager.default.setAttributes([.modificationDate: daysAgo(age)], ofItemAtPath: box.root.appending(path: path + "/info.plist").path)
        return box.root.appending(path: path)
    }

    static func context(_ home: URL, open: [String] = [], now: Date = .now, memory: BorrowerMemory? = nil) -> ScanContext {
        ScanContext(home: home, now: now, openFiles: OpenFiles.parse(lsofOutput(open)), runningBundleIDs: [], installedBundleIDs: [],
                    borrowerMemory: memory)
    }

    // MARK: The walk

    @Test func itFindsABuildCacheOutsideTheUsualPlacesAtAnyDepth() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let near = try Self.derivedData(box, "dev/app/DerivedData/app-1")
        let deep = try Self.derivedData(box, "dev/a/b/c/d/e/f/g/h/i/j/DerivedData/app-2")
        try Self.derivedData(box, "Library/Developer/Xcode/DerivedData/app-usual")
        let found = ProjectDiscovery.walk(home: box.root)
        #expect(Set(found.derivedData.map(\.path)) == [near.path, deep.path] && !found.partial)
    }

    @Test func itKeepsOutOfPersonalPlacesLinksBundlesAndHiddenStores() throws {
        let box = try Sandbox()
        defer { box.remove() }
        for place in ["Library/x/app", ".Trash/app", "Documents/app", "Desktop/app", "Downloads/app", "Pictures/app", ".cache/app",
                      "dev/Tool.app/Contents/app", "dev/p/.git/app", "dev/p/node_modules/app", "dev/p/SourcePackages/app"] {
            try Self.derivedData(box, place)
        }
        let target = try Self.derivedData(box, "elsewhere-real/app")
        _ = try box.link("dev/linked", to: target.deletingLastPathComponent())
        let found = ProjectDiscovery.walk(home: box.root)
        #expect(found.derivedData.map(\.path) == [target.path])
        #expect(found.skipped.contains("링크 1곳") && found.skipped.contains("앱·패키지 묶음 1곳"))
        #expect(found.skipped.contains { $0.hasPrefix("~/Library") } && found.skipped.contains("휴지통") && found.skipped.contains("문서(권한 창)"))
    }

    @Test func aWalkPastItsBudgetSaysItIsPartial() throws {
        let box = try Sandbox()
        defer { box.remove() }
        for index in 0..<20 { try box.folder("dev/p\(index)/src") }
        try Self.derivedData(box, "dev/p0/DerivedData/app")
        let cut = ProjectDiscovery.walk(home: box.root, budget: .init(time: .seconds(60), items: 5))
        #expect(cut.partial)
        let timed = ProjectDiscovery.walk(home: box.root, budget: .init(time: .zero, items: 1_000))
        #expect(timed.partial && timed.derivedData.isEmpty)
    }

    // MARK: Its rows

    @Test func aFoundCacheIsJudgedLikeAUsualOneAndOnlyChosenByHand() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let quiet = try Self.derivedData(box, "dev/a/DerivedData/quiet")
        let fresh = try Self.derivedData(box, "dev/b/DerivedData/fresh", age: 0)
        let open = try Self.derivedData(box, "dev/c/DerivedData/open")
        let context = Self.context(box.root, open: [open.appending(path: "Build/blob").path])
        let rows = Dictionary(uniqueKeysWithValues: ProjectOutputScanner.rows([quiet, fresh, open], context: context, lending: .init(), reprove: true)
            .map { ($0.targets[0].path.path, $0) })
        let ready = try #require(rows[quiet.path])
        #expect(ready.verdict.status == .ready && ready.manualOnly && !ready.isPreselected && !ready.isShallow && ready.isSelectable)
        #expect(ready.targets[0].grant == TargetGrant(kind: .derivedData, path: quiet))
        #expect(rows[fresh.path]?.verdict.reason == "최근에 썼습니다.")
        #expect(rows[open.path]?.verdict.reason == "지금 쓰는 파일이 있습니다")
        let lent = ProjectOutputScanner.rows([quiet], context: context, lending: .init(borrowers: [quiet.path: ["/x/.git/objects/info/alternates"]]), reprove: true)
        #expect(lent.first?.verdict.reason == "다른 캐시가 이 캐시의 패키지 기록을 빌려 씁니다")
    }

    // MARK: The coordinator

    final class Counts: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]
        func add(_ key: String) { lock.withLock { counts[key, default: 0] += 1 } }
        func of(_ key: String) -> Int { lock.withLock { counts[key] ?? 0 } }
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var on: Bool
        init(_ on: Bool) { self.on = on }
        var value: Bool { get { lock.withLock { on } } set { lock.withLock { on = newValue } } }
    }

    /// A coordinator on `home` that counts the walk, the runtime listing and the re-proof; the usual areas other than
    /// Xcode's stay empty, so nothing outside the sandbox is read.
    @MainActor static func coordinator(_ home: URL, counts: Counts, memory: BorrowerMemory, open: Flag = Flag(false),
                                       walkDelay: Double = 0) -> CleanupCoordinator {
        var scanning = CleanupCoordinator.Scanning()
        let defaults = scanning
        let inside = home.appending(path: "Library/Developer/Xcode/DerivedData/app-borrower/Build/blob").path
        scanning.context = { _ in Self.context(home, open: open.value ? [inside] : [], memory: memory) }
        scanning.area = { area, context in
            if area == .runtimes { counts.add("runtimes"); return [] }
            if area == .jobs { counts.add("jobs"); return [] }
            return area == .xcode ? XcodeCacheScanner.scan(context) : []
        }
        scanning.discover = { context in
            counts.add("walk")
            if walkDelay > 0 { Thread.sleep(forTimeInterval: walkDelay) }
            return defaults.discover(context)
        }
        scanning.reprove = { context, caches in counts.add("reprove"); return defaults.reprove(context, caches) }
        return CleanupCoordinator(scanning: scanning)
    }

    @MainActor @Test func theLoopsScanNeverWalksListsRuntimesOrReproves() async throws {
        let f = try BrokenCheckoutTests.make()
        defer { f.box.remove() }
        let home = URL(fileURLWithPath: PathGuard.realPath(f.box.root)!)
        let counts = Counts()
        let coordinator = Self.coordinator(home, counts: counts, memory: BorrowerMemory(url: home.appending(path: "support/b.json")))
        await coordinator.scan()
        #expect(counts.of("walk") == 0 && counts.of("runtimes") == 0 && counts.of("jobs") == 0 && counts.of("reprove") == 0)
        #expect(coordinator.projectsScannedAt == nil && coordinator.candidates[.projects] == nil)
        await coordinator.scanProjects()
        #expect(counts.of("walk") == 1 && counts.of("runtimes") == 1 && counts.of("jobs") == 1 && counts.of("reprove") == 1)
        #expect(coordinator.projectsScannedAt != nil && coordinator.scannedAt != nil)
    }

    @MainActor @Test func settlingDuringARunDoesNotWaitForAScanThatHasNotStarted() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let deleting = Flag(true)
        let coordinator = Self.coordinator(box.root, counts: Counts(), memory: BorrowerMemory(url: box.root.appending(path: "b.json")),
                                           walkDelay: 0.5)
        coordinator.isDeleting = { deleting.value }
        let expanded = Task { await coordinator.scanProjects() }
        try await Task.sleep(for: .milliseconds(100))
        let started = Date.now
        await coordinator.settled()
        #expect(Date.now.timeIntervalSince(started) < 1 && coordinator.projectsScannedAt == nil)
        // Once it runs, a run that starts waits for it.
        deleting.value = false
        try await Task.sleep(for: .milliseconds(400))
        await coordinator.settled()
        #expect(coordinator.projectsScannedAt != nil)
        await expanded.value
    }

    /// The usual row of a cache whose package checkout lost its lender is protected by the alarm; the expanded scan
    /// proves it again, and the dashboard deletes it while a run nobody chose does not.
    @MainActor @Test func aReprovenRowIsAChoiceUntilTheUsualScanSeesItInUse() async throws {
        let f = try BrokenCheckoutTests.make()
        defer { f.box.remove() }
        let home = URL(fileURLWithPath: PathGuard.realPath(f.box.root)!)
        let open = Flag(false)
        let coordinator = Self.coordinator(home, counts: Counts(), memory: BorrowerMemory(url: home.appending(path: "support/b.json")), open: open)
        await coordinator.scan()
        let usual = try #require(coordinator.all.first { $0.targets.contains { $0.path.lastPathComponent == "app-borrower" } })
        #expect(usual.verdict.status == .protected && !usual.manualOnly)

        await coordinator.scanProjects()
        let lifted = try #require(coordinator.all.first { $0.id == usual.id })
        #expect(lifted.isSelectable && lifted.manualOnly && lifted.reproved && !lifted.isPreselected && !lifted.isShallow)
        // A later usual scan keeps the lift while nothing changed …
        await coordinator.scan()
        #expect(coordinator.all.first { $0.id == usual.id }?.reproved == true)
        // … and loses it to an open file.
        open.value = true
        await coordinator.scan()
        #expect(coordinator.all.first { $0.id == usual.id }?.verdict.status == .protected)
        open.value = false
        await coordinator.scan()

        // A file changed since (not recently enough to protect it): its last use moved, so the lift no longer fits.
        let newer = f.borrower.appending(path: "SourcePackages/newer")
        try Data([1]).write(to: newer)
        try FileManager.default.setAttributes([.modificationDate: daysAgo(1.5)], ofItemAtPath: newer.path)
        await coordinator.scan()
        #expect(coordinator.all.first { $0.id == usual.id }.map { !$0.reproved && $0.verdict.status == .protected } == true)
        try FileManager.default.removeItem(at: newer)
        await coordinator.scan()

        let row = try #require(coordinator.all.first { $0.id == usual.id && $0.reproved })
        let executor = fixtureExecutor(roots: [home.appending(path: "Library/Developer/Xcode/DerivedData")], audit: home.appending(path: "audit.jsonl"))
        let latest: @Sendable (String) async -> CleanupCandidate? = { id in await MainActor.run { coordinator.all.first { $0.id == id } } }
        let shallow = await executor.run([row], latest: latest, shallow: true) { _ in }
        #expect(shallow.deleted.isEmpty && FileManager.default.fileExists(atPath: f.borrower.path))
        let chosen = await executor.run([row], latest: latest) { _ in }
        #expect(chosen.deleted.map(\.id) == [usual.id] && !FileManager.default.fileExists(atPath: f.borrower.path))
        coordinator.forget([usual.id])
        #expect(coordinator.lifts.isEmpty)
    }

    @MainActor @Test func aStaleExpandedScanLiftsNothing() async throws {
        let f = try BrokenCheckoutTests.make()
        defer { f.box.remove() }
        let home = URL(fileURLWithPath: PathGuard.realPath(f.box.root)!)
        let memory = BorrowerMemory(url: home.appending(path: "support/b.json"))
        var scanning = CleanupCoordinator.Scanning()
        let old = Flag(false)
        scanning.context = { _ in Self.context(home, now: old.value ? .now.addingTimeInterval(-3_600) : .now, memory: memory) }
        scanning.area = { area, context in area == .xcode ? XcodeCacheScanner.scan(context) : [] }
        let coordinator = CleanupCoordinator(scanning: scanning)
        await coordinator.scan()
        old.value = true
        await coordinator.scanProjects()
        #expect(!coordinator.lifts.isEmpty)
        let row = try #require(coordinator.all.first { $0.targets.contains { $0.path.lastPathComponent == "app-borrower" } })
        #expect(row.verdict.status == .protected && !row.reproved)
    }

    /// A build cache inside a project folder, outside every allowed root: the dashboard deletes exactly it.
    @MainActor @Test func aFoundCacheIsDeletedByItsGrantAndNothingBesideIt() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let found = try Self.derivedData(box, "dev/app/DerivedData/app-x")
        let sibling = try Self.derivedData(box, "dev/app/DerivedData/app-y", age: 0)
        let source = try box.file("dev/app/src/main.swift", modified: daysAgo(2))
        let coordinator = Self.coordinator(box.root, counts: Counts(), memory: BorrowerMemory(url: box.root.appending(path: "b.json")))
        await coordinator.scanProjects()
        let row = try #require(coordinator.all.first { $0.targets.first?.path.path == found.path })
        #expect(row.isSelectable && row.manualOnly)
        #expect(coordinator.all.first { $0.targets.first?.path.path == sibling.path }?.isSelectable == false)

        let executor = fixtureExecutor(roots: [], audit: box.root.appending(path: "audit.jsonl")) { $0.home = box.root }
        let latest: @Sendable (String) async -> CleanupCandidate? = { id in await MainActor.run { coordinator.all.first { $0.id == id } } }
        let report = await executor.run([row], latest: latest) { _ in }
        #expect(report.deleted.count == 1 && !FileManager.default.fileExists(atPath: found.path))
        #expect(FileManager.default.fileExists(atPath: sibling.path) && FileManager.default.fileExists(atPath: source.path))
    }
}
