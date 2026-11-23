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

    static func context(_ home: URL, open: [String] = [], now: Date = .now, memory: BorrowerMemory? = nil,
                        ages: CleanupAges = CleanupAges()) -> ScanContext {
        ScanContext(home: home, now: now, openFiles: OpenFiles.parse(lsofOutput(open)), runningBundleIDs: [], installedBundleIDs: [],
                    ages: ages, borrowerMemory: memory)
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
        #expect(ready.verdict.status == .ready && !ready.manualOnly && ready.isPreselected && !ready.isShallow && ready.isSelectable && !ready.reproved)
        #expect(ready.targets[0].grant == TargetGrant(kind: .derivedData, path: quiet))
        #expect(rows[fresh.path]?.verdict.reason == "최근에 썼습니다.")
        #expect(rows[open.path]?.verdict.reason == "지금 쓰는 파일이 있습니다")
        let lent = ProjectOutputScanner.rows([quiet], context: context, lending: .init(borrowers: [quiet.path: ["/x/.git/objects/info/alternates"]]), reprove: true)
        #expect(lent.first?.verdict.reason == "다른 캐시가 이 캐시의 패키지 기록을 빌려 씁니다")
    }

    /// A judge that answers in turn (the last answer repeats), noting the proof mode each call asked for.
    static func scripted(_ answers: [(refusal: String?, alarm: String?)], modes: ScanDeadlineTests.Seen<Bool>) -> ProjectOutputScanner.Judge {
        { _, inputs in
            let answer = answers[min(modes.all.count, answers.count - 1)]
            modes.add(inputs.reprove)
            return (answer.refusal, TreeFacts(bytes: 2_000_000, files: 1, newest: daysAgo(2), alarm: answer.alarm))
        }
    }

    static func judgedRow(_ answers: [(refusal: String?, alarm: String?)], reprove: Bool = true, lending: XcodeCacheScanner.Lending = .init())
        throws -> (row: CleanupCandidate, modes: [Bool]) {
        let modes = ScanDeadlineTests.Seen<Bool>()
        let rows = ProjectOutputScanner.rows([URL(fileURLWithPath: "/tmp/dev/DerivedData/app")], context: Self.context(URL(fileURLWithPath: "/tmp")),
                                             lending: lending, reprove: reprove, judge: Self.scripted(answers, modes: modes))
        return (try #require(rows.first), modes.all)
    }

    static let alarm = (refusal: Optional(CacheRules.alarmReason("credentials")), alarm: Optional("credentials"))

    @Test func aCacheThatPassesWithoutReprovingIsTickedButNeverShallow() throws {
        let (row, modes) = try Self.judgedRow([(nil, nil)])
        #expect(row.isPreselected && !row.isShallow && !row.reproved && !row.manualOnly)
        #expect(modes == [false])
    }

    @Test func aCacheOnlyAReproofClearsIsAChoiceOnly() throws {
        let (row, modes) = try Self.judgedRow([Self.alarm, (nil, nil)])
        #expect(row.manualOnly && row.reproved && row.isSelectable && !row.isPreselected)
        #expect(modes == [false, true])
    }

    @Test func withoutLeaveToReproveAnAlarmKeepsTheCache() throws {
        let (row, modes) = try Self.judgedRow([Self.alarm], reprove: false)
        #expect(!row.isSelectable && !row.reproved && modes == [false])
    }

    @Test func anAlarmTheReproofDoesNotClearKeepsTheCache() throws {
        let (row, modes) = try Self.judgedRow([Self.alarm, Self.alarm])
        #expect(!row.isSelectable && row.reproved && modes == [false, true])
    }

    @Test func everyOtherRefusalStaysAsItWasAfterOneJudgement() throws {
        for reason in ["작업 공간 기록을 읽지 못했습니다", "Xcode 빌드 캐시 모양이 아닙니다", "다 훑지 못해 마지막 사용 시각을 모릅니다", "최근에 썼습니다.",
                       "열린 파일을 확인하지 못했습니다", "지금 쓰는 파일이 있습니다", "다른 캐시가 이 캐시의 패키지 기록을 빌려 씁니다", ProjectOutputScanner.outOfTime] {
            let (row, modes) = try Self.judgedRow([(reason, nil)])
            #expect(row.evidence.protectedReason == reason && !row.isSelectable && modes == [false], "\(reason)")
        }
    }

    @Test func anUnreadableBorrowerMemoryMakesEveryCacheAChoice() throws {
        var lending = XcodeCacheScanner.Lending()
        lending.memoryCorrupt = true
        let (row, _) = try Self.judgedRow([(nil, nil)], lending: lending)
        #expect(row.manualOnly && !row.isPreselected && !row.reproved)
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

    /// Holds whoever passes while it is shut, at most ten seconds, until `open()`; once open, nobody waits.
    final class Hold: @unchecked Sendable {
        private let lock = NSLock()
        private let gate = DispatchSemaphore(value: 0)
        private var shut: Bool
        private var waiting = 0
        init(shut: Bool = false) { self.shut = shut }
        var held: Int { lock.withLock { waiting } }
        func close() { lock.withLock { shut = true } }
        func pass() {
            let wait = lock.withLock {
                if shut { waiting += 1 }
                return shut
            }
            guard wait else { return }
            _ = gate.wait(timeout: .now() + 10)
            lock.withLock { waiting -= 1 }
        }
        func open() {
            let count = lock.withLock {
                shut = false
                return waiting
            }
            for _ in 0..<count { gate.signal() }
        }
    }

    struct TimedOut: Error {}

    /// Waits until `condition` holds, looking every 10 ms, for at most ten seconds.
    @MainActor static func until(_ condition: @MainActor () -> Bool) async throws {
        let deadline = Date.now.addingTimeInterval(10)
        while !condition() {
            guard Date.now < deadline else { throw TimedOut() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// A coordinator on `home` that counts Xcode's usual scan, the walk, the runtime listing and the re-proof; the usual
    /// areas other than Xcode's stay empty and the runtimes and jobs list only `listed`, so nothing outside the sandbox
    /// is read. `usual` and `walk` hold Xcode's usual scan and the walk.
    @MainActor static func coordinator(_ home: URL, counts: Counts, memory: BorrowerMemory, open: Flag = Flag(false),
                                       settings: CleanupSettings? = nil, usual: Hold = Hold(), walk: Hold = Hold(),
                                       listed: [CleanupCoordinator.Area: [CleanupCandidate]] = [:], judgeBudget: Duration? = nil) -> CleanupCoordinator {
        var scanning = CleanupCoordinator.Scanning()
        let defaults = scanning
        if let judgeBudget { scanning.judgeBudget = judgeBudget }
        let inside = home.appending(path: "Library/Developer/Xcode/DerivedData/app-borrower/Build/blob").path
        scanning.context = { ages in Self.context(home, open: open.value ? [inside] : [], memory: memory, ages: ages) }
        scanning.area = { area, context in
            if area == .runtimes { counts.add("runtimes"); return listed[.runtimes] ?? [] }
            if area == .jobs { counts.add("jobs"); return listed[.jobs] ?? [] }
            guard area == .xcode else { return [] }
            counts.add("xcode")
            usual.pass()
            return XcodeCacheScanner.scan(context)
        }
        scanning.discover = { context in
            counts.add("walk")
            walk.pass()
            return defaults.discover(context)
        }
        scanning.reprove = { context, caches in counts.add("reprove"); return defaults.reprove(context, caches) }
        return CleanupCoordinator(settings: settings, scanning: scanning)
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
        let walk = Hold(shut: true)
        let coordinator = Self.coordinator(box.root, counts: Counts(), memory: BorrowerMemory(url: box.root.appending(path: "b.json")),
                                           walk: walk)
        coordinator.isDeleting = { deleting.value }
        let expanded = Task { await coordinator.scanProjects() }
        await Task.yield()
        let started = Date.now
        await coordinator.settled()
        #expect(Date.now.timeIntervalSince(started) < 1 && coordinator.projectsScannedAt == nil)
        // Once it runs, a run that starts waits for it.
        deleting.value = false
        try await Self.until { walk.held > 0 }
        let settling = Task { await coordinator.settled() }
        walk.open()
        await settling.value
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

    /// The dashboard runs both scans at once: a re-proof that lands before the usual Xcode rows still lifts them.
    @MainActor @Test func aReproofLandingBeforeTheUsualRowsStillLiftsThem() async throws {
        let f = try BrokenCheckoutTests.make()
        defer { f.box.remove() }
        let home = URL(fileURLWithPath: PathGuard.realPath(f.box.root)!)
        let usual = Hold(shut: true)
        let coordinator = Self.coordinator(home, counts: Counts(), memory: BorrowerMemory(url: home.appending(path: "support/b.json")),
                                           usual: usual)
        let both = Task { await coordinator.scanEverything() }
        try await Self.until { coordinator.projectsScannedAt != nil }
        #expect(coordinator.scanning.contains(.xcode))
        usual.open()
        await both.value
        let row = try #require(coordinator.all.first { $0.targets.contains { $0.path.lastPathComponent == "app-borrower" } })
        #expect(row.isSelectable && row.reproved && row.manualOnly)
    }

    /// A later dashboard scan whose re-proof lands before the usual Xcode rows shows no lift from the scan before it.
    @MainActor @Test func aLaterReproofLandingFirstDropsTheLiftsOfTheScanBefore() async throws {
        let f = try BrokenCheckoutTests.make()
        defer { f.box.remove() }
        let home = URL(fileURLWithPath: PathGuard.realPath(f.box.root)!)
        let usual = Hold()
        let coordinator = Self.coordinator(home, counts: Counts(), memory: BorrowerMemory(url: home.appending(path: "support/b.json")),
                                           usual: usual)
        await coordinator.scanEverything()
        let first = try #require(coordinator.projectsScannedAt)
        #expect(!coordinator.lifts.isEmpty)
        usual.close()
        let again = Task { await coordinator.scanEverything(force: true) }
        try await Self.until { coordinator.projectsScannedAt.map { $0 > first } == true }
        #expect(coordinator.scanning.contains(.xcode) && coordinator.lifts.isEmpty)
        usual.open()
        await again.value
        #expect(!coordinator.lifts.isEmpty)
    }

    /// Settings changed after the re-proof: its lifts no longer apply to the usual rows a later scan reads.
    @MainActor @Test func aSettingsChangeAfterTheReproofDropsItsLifts() async throws {
        let f = try BrokenCheckoutTests.make()
        defer { f.box.remove() }
        let home = URL(fileURLWithPath: PathGuard.realPath(f.box.root)!)
        let settings = CleanupSettings(defaults: nil)
        let coordinator = Self.coordinator(home, counts: Counts(), memory: BorrowerMemory(url: home.appending(path: "support/b.json")),
                                           settings: settings)
        await coordinator.scanEverything()
        let usual = try #require(coordinator.all.first { $0.targets.contains { $0.path.lastPathComponent == "app-borrower" } })
        #expect(usual.reproved)
        settings.set(.buildCache, 3)
        await coordinator.scan()
        #expect(coordinator.all.first { $0.id == usual.id }.map { !$0.reproved && $0.verdict.status == .protected } == true)
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
        #expect(row.isSelectable && row.isPreselected && !row.isShallow)
        #expect(coordinator.all.first { $0.targets.first?.path.path == sibling.path }?.isSelectable == false)

        let executor = fixtureExecutor(roots: [], audit: box.root.appending(path: "audit.jsonl")) { $0.home = box.root }
        let latest: @Sendable (String) async -> CleanupCandidate? = { id in await MainActor.run { coordinator.all.first { $0.id == id } } }
        let report = await executor.run([row], latest: latest) { _ in }
        #expect(report.deleted.count == 1 && !FileManager.default.fileExists(atPath: found.path))
        #expect(FileManager.default.fileExists(atPath: sibling.path) && FileManager.default.fileExists(atPath: source.path))
    }
}
