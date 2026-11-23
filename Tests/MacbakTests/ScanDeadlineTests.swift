import Foundation
import Testing
@testable import Macbak

/// The expanded scan's one deadline: every walk, git call and package proof it makes ends by it, a folder reached after
/// it is counted rather than judged, and the usual scan has none.
@Suite struct ScanDeadlineTests {
    static var past: ContinuousClock.Instant { ContinuousClock.now.advanced(by: .seconds(-1)) }

    static func inputs(_ home: URL, deadline: ContinuousClock.Instant?) -> TargetGrant.Inputs {
        TargetGrant.Inputs(now: .now, ages: CleanupAges(), open: OpenFiles.parse(lsofOutput([])), borrowers: [], reprove: false, home: home,
                           deadline: deadline)
    }

    final class Seen<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Value] = []
        func add(_ value: Value) { lock.withLock { values.append(value) } }
        var all: [Value] { lock.withLock { values } }
    }

    @Test func aBudgetIsCutToWhatIsLeft() {
        #expect(ScanSupport.budget(.seconds(60), until: nil) == .seconds(60))
        let soon = ScanSupport.budget(.seconds(60), until: ContinuousClock.now.advanced(by: .seconds(5)))
        #expect(soon > .seconds(4) && soon <= .seconds(5))
        #expect(ScanSupport.budget(.seconds(60), until: Self.past) == .zero)
    }

    @Test func pastTheDeadlineNoKindIsJudged() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let cache = try ProjectDiscoveryTests.derivedData(box, "dev/app/DerivedData/app-1")
        try box.file("dev/web/package.json")
        try box.file("dev/web/node_modules/x/index.js", bytes: 2_000_000, modified: daysAgo(90))
        try box.file("dev/rust/Cargo.toml")
        try box.file("dev/rust/target/debug/blob", bytes: 2_000_000, modified: daysAgo(30))
        let scratch = try JobScratchTests.job(box, "j1")
        let grants = [
            TargetGrant(kind: .derivedData, path: cache),
            TargetGrant(kind: .projectArtifact(project: box.root.appending(path: "dev/rust")), path: box.root.appending(path: "dev/rust/target")),
            TargetGrant(kind: .nodeModules, path: box.root.appending(path: "dev/web/node_modules")),
            TargetGrant(kind: .jobScratch, path: scratch),
        ]
        for grant in grants {
            let late = TargetGrant.evaluate(grant, Self.inputs(box.root, deadline: Self.past))
            #expect(late.refusal == ProjectOutputScanner.outOfTime && late.facts.files == 0, "\(grant.kind)")
            let open = TargetGrant.evaluate(grant, Self.inputs(box.root, deadline: nil))
            #expect(open.refusal != ProjectOutputScanner.outOfTime && open.facts.files > 0, "\(grant.kind)")
        }
    }

    @Test func aProjectsLastActivityIsUnknownPastTheDeadline() throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.file("web/package.json", modified: daysAgo(3))
        try box.file("web/index.js", modified: daysAgo(3))
        let project = box.root.appending(path: "web")
        #expect(NodeModules.lastActivity(project) != nil)
        #expect(NodeModules.lastActivity(project, until: Self.past) == nil)
    }

    @Test func theJudgingBudgetIsFourMinutes() {
        #expect(CleanupCoordinator.Scanning().judgeBudget == .seconds(240))
    }

    /// On a real broken checkout and a build cache outside the usual places: in time, both are judged and the checkout
    /// proven again; with no time, neither, and the walk says what it left.
    @MainActor @Test func theCoordinatorStopsJudgingAtItsDeadline() async throws {
        for budget in [Duration.seconds(240), .zero] {
            let f = try BrokenCheckoutTests.make()
            defer { f.box.remove() }
            try ProjectDiscoveryTests.derivedData(f.box, "dev/app/DerivedData/app-x")
            let home = URL(fileURLWithPath: PathGuard.realPath(f.box.root)!)
            let counts = ProjectDiscoveryTests.Counts()
            let coordinator = ProjectDiscoveryTests.coordinator(home, counts: counts, memory: BorrowerMemory(url: home.appending(path: "support/b.json")),
                                                                judgeBudget: budget)
            await coordinator.scan()
            await coordinator.scanProjects()
            let rows = coordinator.candidates[.projects] ?? []
            if budget == .zero {
                #expect(counts.of("reprove") == 0 && rows.isEmpty)
                #expect(coordinator.discovery?.partial == true && coordinator.discovery?.skipped.contains("시간이 다 돼 판정하지 못한 폴더 1곳") == true)
            } else {
                #expect(counts.of("reprove") == 1 && rows.contains { $0.targets.first?.path.lastPathComponent == "app-x" })
                #expect(coordinator.discovery?.skipped.contains { $0.hasPrefix("시간이 다 돼") } == false)
            }
        }
    }

    @MainActor @Test func theUsualScanHasNoDeadline() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let seen = Seen<String>()
        var scanning = CleanupCoordinator.Scanning()
        scanning.context = { ages in ProjectDiscoveryTests.context(box.root, ages: ages) }
        scanning.area = { area, context in
            seen.add("\(area.rawValue):\(context.deadline == nil ? "none" : "set")")
            return []
        }
        let coordinator = CleanupCoordinator(scanning: scanning)
        await coordinator.scan()
        #expect(Set(seen.all) == ["xcode:none", "appCaches:none", "devices:none", "general:none"])
        await coordinator.scanProjects()
        #expect(seen.all.contains("runtimes:set") && seen.all.contains("jobs:set"))
    }

    @Test func aWalkStopsAtItsDeadline() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let folder = try box.folder("many")
        for index in 0..<3_000 { try box.file("many/f\(index)", bytes: 1) }
        let calls = Seen<Bool>()
        let alarm: @Sendable (URL, Bool) -> Bool = { _, _ in calls.add(true); return false }
        let late = TreeWalk.inspect(folder, until: Self.past, alarm: alarm)
        #expect(late.gap == "시간 초과" && late.files == 0 && calls.all.isEmpty)
        let all = TreeWalk.inspectAll([folder, folder], until: Self.past, alarm: alarm)
        #expect(all.allSatisfy { $0.gap == "시간 초과" && $0.files == 0 } && calls.all.isEmpty)
        let cut = TreeWalk.inspect(folder, until: ContinuousClock.now.advanced(by: .milliseconds(1)))
        #expect(cut.gap == "시간 초과" && cut.files < 3_000)
        let whole = TreeWalk.inspect(folder)
        #expect(whole.isComplete && whole.files == 3_000)
    }

    /// The three row builders and the job scanner hand every folder the context's one deadline.
    @Test func everyFolderGetsTheSameDeadline() throws {
        let box = try Sandbox()
        defer { box.remove() }
        try JobScratchTests.job(box, "j1")
        try JobScratchTests.job(box, "j2")
        let seen = Seen<ContinuousClock.Instant?>()
        let judge: ProjectOutputScanner.Judge = { _, inputs in
            seen.add(inputs.deadline)
            return ("spy", TreeFacts(gap: "spy"))
        }
        var context = ProjectDiscoveryTests.context(box.root)
        let deadline = ContinuousClock.now.advanced(by: .seconds(100))
        context.deadline = deadline
        let folders = ["a", "b"].map { box.root.appending(path: "dev/\($0)") }
        _ = ProjectOutputScanner.rows(folders, context: context, lending: .init(), reprove: false, judge: judge)
        _ = ProjectOutputScanner.artifactRows(folders.map { ProjectDiscovery.Artifact(project: $0, folder: $0.appending(path: "build")) },
                                              context: context, judge: judge)
        _ = ProjectOutputScanner.nodeModulesRows(folders.map { $0.appending(path: "node_modules") }, context: context, judge: judge)
        _ = JobScratchScanner.scan(context, judge: judge)
        #expect(seen.all.count == 8 && seen.all.allSatisfy { $0 == deadline })
    }

    @Test func theReproofPathEndsAtTheDeadline() throws {
        let f = try BrokenCheckoutTests.make()
        defer { f.box.remove() }
        let only: Set = [f.borrower.path(percentEncoded: false)]
        var late = f.context()
        late.deadline = Self.past
        #expect(XcodeCacheScanner.scan(late, only: only, reprove: true).allSatisfy { !$0.isSelectable })
        let proven = try #require(XcodeCacheScanner.scan(f.context(), only: only, reprove: true).first)
        #expect(proven.isSelectable && proven.reproved)
    }

    @Test func theProofAndGitAnswerNothingPastTheDeadline() throws {
        let f = try BrokenCheckoutTests.make()
        defer { f.box.remove() }
        #expect(PackageCheckout.isPristine(f.alarm, reprove: true))
        #expect(!PackageCheckout.isPristine(f.alarm, reprove: true, until: Self.past))

        let project = try f.box.folder("p")
        try "build/\n".write(to: project.appending(path: ".gitignore"), atomically: true, encoding: .utf8)
        try #require(Command.run("/usr/bin/git", ["-C", project.path(percentEncoded: false), "init", "-q"], timeout: .seconds(30))?.status == 0)
        let build = try f.box.folder("p/build")
        #expect(Git.isIgnored(build, project: project) == true)
        #expect(Git.isIgnored(build, project: project, until: Self.past) == nil)
    }
}
