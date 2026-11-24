import Foundation
import Testing
@testable import Macbak

/// A one-shot gate, opened by the test.
private actor Latch {
    private var open = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if open { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func openUp() {
        open = true
        waiting.forEach { $0.resume() }
        waiting = []
    }
}

/// Counts the scans that built their context, and holds the next one when asked to.
private actor ScanGate {
    private(set) var entered = 0
    private var holding = false
    private let latch = Latch()

    func holdNext() { holding = true }
    func release() async { await latch.openUp() }

    func enter() async {
        entered += 1
        guard holding else { return }
        holding = false
        await latch.wait()
    }
}

@MainActor
private func eventually(_ what: String, _ condition: () async -> Bool) async {
    let until = ContinuousClock.now + .seconds(5)
    while await !condition() {
        guard ContinuousClock.now < until else {
            Issue.record("never happened: \(what)")
            return
        }
        await Task.yield()
    }
}

/// A person's rules: one exact folder each, approved after the on-device model proposed it, kept in a file that a
/// damaged or newer copy never lets anything write over. A rule only turns a row nothing could tell into a choice
/// nobody ticks, and the executor reads the rules again before deleting.
@Suite(.timeLimit(.minutes(1))) struct UserRulesTests {
    /// A folder the frozen rules cannot tell (`model`), outside the cache areas.
    static let unknown = "Library/Application Support/SomeApp/blob"

    static func home() throws -> Sandbox {
        let box = try Sandbox()
        let old = daysAgo(10)
        try box.file(unknown + "/a1b2c3", bytes: 1_500_000, modified: old)
        try box.file(unknown + "/d4e5f6", bytes: 1_500_000, modified: old)
        return box
    }

    static func rows(_ box: Sandbox, rules: Set<String> = []) -> [String: CleanupCandidate] {
        var context = ScanContext(home: box.root, now: .now, openFiles: OpenFiles.parse(lsofOutput([])), runningBundleIDs: [], installedBundleIDs: [])
        context.userRules = rules
        return Dictionary(uniqueKeysWithValues: GeneralCacheScanner.scan(context).map { ($0.id, $0) })
    }

    static func id(_ relative: String) -> String { "general." + PathKey.fold(relative) }

    static func roots(_ box: Sandbox) -> Set<String> {
        Set(CleanupRoots.ruleRoots(home: box.root).map(GeneralizationRulesTests.folder))
    }

    static func bytes(_ store: UserRuleStore) -> Data? { try? Data(contentsOf: store.url) }

    @Test func rulesSurviveARoundTrip() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let store = UserRuleStore(home: box.root)
        #expect(store.load() == .none)
        #expect(store.approve("a/b") && store.approve("c d/e"))
        #expect(UserRuleStore(home: box.root).load() == .rules(["a/b", "c d/e"]))
        #expect(store.revoke("a/b"))
        #expect(store.load() == .rules(["c d/e"]))
        let data = try #require(Self.bytes(store))
        let saved = try #require(String(data: data, encoding: .utf8))
        #expect(saved.contains("\"schemaVersion\":1"))
    }

    @Test func aDamagedOrNewerFileMeansNoRulesAndStaysAsItIs() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let store = UserRuleStore(home: box.root)
        for content in ["not json", #"{"schemaVersion":2,"folders":["a/b"]}"#, #"{"folders":["a/b"]}"#] {
            try box.file("Library/Application Support/Macbak/user-rules.json", bytes: 0)
            try Data(content.utf8).write(to: store.url)
            #expect(store.load() == .unreadable, "\(content)")
            #expect(store.load().paths.isEmpty)
            #expect(!store.approve("x/y"), "\(content)")
            #expect(!store.revoke("a/b"), "\(content)")
            #expect(Self.bytes(store) == Data(content.utf8), "\(content) is left as it was")
        }
    }

    @Test func twoStoresTakingTurnsLoseNothing() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let first = UserRuleStore(home: box.root)
        let second = UserRuleStore(home: box.root)
        #expect(first.approve("a") && second.approve("b") && first.approve("c") && second.revoke("a"))
        #expect(first.load() == .rules(["b", "c"]))
        // Many at once, from two stores: each change reads the file again under the lock, so none is lost.
        let stores = [first, second]
        DispatchQueue.concurrentPerform(iterations: 40) { index in
            _ = stores[index % 2].approve("many/\(index)")
        }
        #expect(first.load().paths == Set((0..<40).map { "many/\($0)" }).union(["b", "c"]))
    }

    @Test func aRuleTurnsOnlyAnUnknownIntoAChoice() {
        let unknown = CacheRules.tier(path: Self.unknown, inside: "a1b2c3, d4e5f6", beside: "", userRules: [])
        #expect(unknown.tier == .model)
        let ruled = CacheRules.tier(path: Self.unknown, inside: "a1b2c3, d4e5f6", beside: "", userRules: [Self.unknown])
        #expect(ruled.tier == .offer && ruled.why == CacheRules.userRuleWhy)
        // What the rules already decided stays as it was, rule or not.
        for (path, inside) in [("Library/Application Support/SomeApp/Documents", "report.pdf"),
                               ("Library/Application Support/SomeApp/Code Cache", "js, wasm"),
                               ("Library/Application Support/Adobe/Common/Media Cache", "clip.mcdb")] {
            let before = CacheRules.tier(path: path, inside: inside, beside: "")
            let after = CacheRules.tier(path: path, inside: inside, beside: "", userRules: [path])
            #expect(before.tier != .model, "\(path)")
            #expect(after.tier == before.tier && after.why == before.why, "\(path)")
        }
    }

    /// An approved folder that later shows someone's state (sessions appearing in it) stops being a choice, and the
    /// executor stops accepting it; the rule stays in the file and applies again once the names go.
    @Test func aRuleStopsOnceTheFolderShowsState() throws {
        #expect(CacheRules.tier(path: Self.unknown, inside: "a1b2c3, d4e5f6, sessions/ (x.jsonl)", beside: "", userRules: [Self.unknown]).tier == .model)
        let box = try Self.home()
        defer { box.remove() }
        let folder = GeneralizationRulesTests.folder(box.root.appending(path: Self.unknown))
        #expect(UserRuleStore(home: box.root).approve(Self.unknown))
        #expect(Self.roots(box).contains(folder))
        // Behind more hash-named files than the rules listing shows, so only reading the folder itself finds it.
        for index in 0..<8 { try box.file(Self.unknown + "/0\(index)ab", bytes: 1_000, modified: daysAgo(10)) }
        try box.file(Self.unknown + "/sessions/2026-11-24.jsonl", bytes: 1_000, modified: daysAgo(10))
        #expect(!CacheRules.listing(home: box.root, relative: Self.unknown).inside.contains("sessions"))
        let row = try #require(Self.rows(box, rules: [Self.unknown])[Self.id(Self.unknown)])
        #expect(row.verdict.status == .protected && row.targets.isEmpty)
        #expect(!Self.roots(box).contains(folder))
    }

    @Test func aRuleNeverReachesWhatAToolFreesItself() {
        let toolchains = ".rustup/toolchains"
        #expect(CacheRules.tier(path: toolchains, inside: "stable-aarch64-apple-darwin", beside: "").tier == .model)
        #expect(CacheRules.tier(path: toolchains, inside: "stable-aarch64-apple-darwin", beside: "", userRules: [toolchains]).tier == .model)
    }

    @Test func aRuleIsOneExactFolder() {
        for path in ["Library/Application Support/SomeApp", Self.unknown + "/inner", Self.unknown + "2", "Library/Application Support/SomeApp/Blob"] {
            #expect(CacheRules.tier(path: path, inside: "x", beside: "", userRules: [Self.unknown]).tier == .model, "\(path)")
        }
    }

    @Test func aRuledRowIsNeverTickedNorCleanedWithoutAClick() throws {
        let box = try Self.home()
        defer { box.remove() }
        let before = try #require(Self.rows(box)[Self.id(Self.unknown)])
        #expect(before.verdict.status == .protected && before.targets.isEmpty)
        #expect(!Self.roots(box).contains(GeneralizationRulesTests.folder(box.root.appending(path: Self.unknown))))

        let ruled = try #require(Self.rows(box, rules: [Self.unknown])[Self.id(Self.unknown)])
        #expect(ruled.verdict.status == .review && ruled.isSelectable)
        #expect(ruled.verdict.reason == CacheRules.costReason(CacheRules.Verdict(tier: .offer, why: CacheRules.userRuleWhy, devRow: nil)))
        #expect(!ruled.isPreselected && !ruled.isShallow)
        #expect(ruled.askInput == nil && ruled.exploreInput == nil)
        #expect(UserRuleStore(home: box.root).approve(Self.unknown))
        #expect(Self.roots(box).contains(GeneralizationRulesTests.folder(box.root.appending(path: Self.unknown))))
    }

    @Test func revokingTakesTheFolderAwayFromTheExecutor() throws {
        let box = try Self.home()
        defer { box.remove() }
        let store = UserRuleStore(home: box.root)
        let folder = GeneralizationRulesTests.folder(box.root.appending(path: Self.unknown))
        #expect(store.approve(Self.unknown))
        #expect(Self.roots(box).contains(folder))
        #expect(store.revoke(Self.unknown))
        #expect(!Self.roots(box).contains(folder))
    }

    @Test func aKeyInsideKeepsARuledRow() throws {
        let box = try Self.home()
        defer { box.remove() }
        // Deeper than the names the rules list (`sub/ (deeper/)`): only the deep alarm sees it.
        try box.file(Self.unknown + "/sub/deeper/id_ed25519", bytes: 400, modified: daysAgo(10))
        #expect(Self.rows(box)[Self.id(Self.unknown)]?.askInput == nil, "a key inside: the model is not asked")
        let classified = try #require(GeneralCacheScanner.classify(home: box.root, userRules: [Self.unknown]).first { $0.relative == Self.unknown })
        #expect(classified.rules.tier == .offer, "the rule alone would make it a choice")
        let row = try #require(Self.rows(box, rules: [Self.unknown])[Self.id(Self.unknown)])
        #expect(row.verdict.status == .protected && row.targets.isEmpty)
        #expect(row.askInput == nil)
    }

    @Test func onlyFoldersAreAsked() throws {
        let box = try Self.home()
        defer { box.remove() }
        let old = daysAgo(10)
        try box.file("Library/Application Support/SomeApp/blob.bin", bytes: 2_000_000, modified: old)
        try box.file(".cache/thing/state.json", bytes: 1_000, modified: old)
        try box.file(".cache/thing/a.bin", bytes: 2_000_000, modified: old)
        try box.file(".rustup/toolchains/stable-aarch64-apple-darwin/bin/rustc", bytes: 2_000_000, modified: old)
        try box.file("Library/Application Support/SomeApp/Documents/report.pdf", bytes: 2_000_000, modified: old)
        try box.folder("Library/Application Support/SomeApp/empty")
        let found = Self.rows(box)
        let empty = try #require(found[Self.id("Library/Application Support/SomeApp/empty")])
        #expect(empty.askInput == nil, "nothing for the model to look at")
        #expect(found[Self.id(Self.unknown)]?.askInput?.relative == Self.unknown, "a folder nothing could tell")
        #expect(found[Self.id(Self.unknown)]?.exploreInput == nil)
        let file = try #require(found[Self.id("Library/Application Support/SomeApp/blob.bin")])
        #expect(file.verdict.status == .protected && file.askInput == nil, "a file: a rule would open its parent")
        let playground = try #require(found[Self.id(".cache/thing")])
        #expect(playground.exploreInput != nil && playground.askInput == nil, "the explorer looks there by itself")
        #expect(found[Self.id(".rustup/toolchains")]?.askInput == nil, "its tool frees it")
        let documents = try #require(found[Self.id("Library/Application Support/SomeApp/Documents")])
        #expect(documents.askInput == nil, "the rules keep it")
    }

    /// A scan that read the rules before an approval is waited for, and a new scan then shows the rule.
    @MainActor @Test func aRuleChangeRescansAfterTheScanInProgress() async throws {
        let box = try Self.home()
        defer { box.remove() }
        let gate = ScanGate()
        var scanning = CleanupCoordinator.Scanning()
        scanning.context = { ages in
            let rules = UserRuleStore(home: box.root).load().paths
            await gate.enter()
            var context = ProjectDiscoveryTests.context(box.root, ages: ages)
            context.userRules = rules
            return context
        }
        scanning.area = { area, context in area == .general ? GeneralCacheScanner.scan(context) : [] }
        let advisor = RuleAdvisor(slot: ModelSlot(), look: { _ in .init(offered: true, decision: "regenerable", evidence: "hash-named files") },
                                  unavailable: { nil })
        let coordinator = CleanupCoordinator(scanning: scanning, advisor: advisor, rules: UserRuleStore(home: box.root))
        let id = Self.id(Self.unknown)
        await coordinator.scan()
        let input = try #require(coordinator.all.first { $0.id == id }?.askInput)
        coordinator.ask([id])
        await eventually("proposed") { advisor.answer(for: id, input: input) == .proposal(evidence: "hash-named files") }

        await gate.holdNext()
        let inProgress = Task { await coordinator.scan() }
        await eventually("the scan read the rules") { await gate.entered == 2 }
        let approval = Task { await coordinator.approve(id) }
        try await Task.sleep(for: .milliseconds(50))
        await gate.release()
        await inProgress.value
        #expect(await approval.value)
        let row = try #require(coordinator.all.first { $0.id == id })
        #expect(row.verdict.status == .review && !row.isPreselected && !row.targets.isEmpty)
        #expect(await gate.entered == 3, "one scan after the one in progress")
    }

    @MainActor @Test func rulesDoNotChangeWhileDeleting() async throws {
        let box = try Self.home()
        defer { box.remove() }
        var scanning = CleanupCoordinator.Scanning()
        scanning.context = { ages in
            var context = ProjectDiscoveryTests.context(box.root, ages: ages)
            context.userRules = UserRuleStore(home: box.root).load().paths
            return context
        }
        scanning.area = { area, context in area == .general ? GeneralCacheScanner.scan(context) : [] }
        let advisor = RuleAdvisor(slot: ModelSlot(), look: { _ in .init(offered: true, decision: "regenerable", evidence: "e") }, unavailable: { nil })
        let store = UserRuleStore(home: box.root)
        let coordinator = CleanupCoordinator(scanning: scanning, advisor: advisor, rules: store)
        let id = Self.id(Self.unknown)
        #expect(store.approve("other/folder"))
        await coordinator.scan()
        #expect(!(await coordinator.approve(id)), "nothing proposed it yet")
        let input = try #require(coordinator.all.first { $0.id == id }?.askInput)
        coordinator.ask([id])
        await eventually("proposed") { advisor.answer(for: id, input: input) == .proposal(evidence: "e") }
        let saved = Self.bytes(store)

        coordinator.isDeleting = { true }
        #expect(!(await coordinator.approve(id)))
        #expect(!(await coordinator.revoke("other/folder")))
        #expect(Self.bytes(store) == saved)
        #expect(coordinator.rulesChanged == 0)

        coordinator.isDeleting = { false }
        #expect(await coordinator.approve(id))
        #expect(store.load() == .rules(["other/folder", Self.unknown]))
        #expect(coordinator.rulesChanged == 1, "a screen listing the rules reads them again")
        #expect(await coordinator.revoke("other/folder"))
        #expect(coordinator.rulesChanged == 2)
    }
}
