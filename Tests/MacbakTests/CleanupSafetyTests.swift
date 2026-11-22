import Foundation
import Testing
@testable import Macbak

// Each test breaks exactly one safety gate, so removing that gate makes exactly that test fail.
// Everything happens in a fresh temporary folder; no test touches the user's own files.

struct Sandbox {
    /// Resolved through `/private`, the way scanners build their paths.
    let root: URL

    init() throws {
        let base = URL(fileURLWithPath: PathGuard.realPath(URL(fileURLWithPath: NSTemporaryDirectory()))!)
        root = base.appending(path: "macbak-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    @discardableResult
    func folder(_ path: String) throws -> URL {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    func file(_ path: String, bytes: Int = 16, modified: Date? = nil) throws -> URL {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
        return url
    }

    func link(_ path: String, to destination: URL) throws -> URL {
        let url = root.appending(path: path)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: destination)
        return url
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

func daysAgo(_ days: Double) -> Date { Date.now.addingTimeInterval(-days * 86_400) }

// MARK: - Tree walk

@Test func treeWalkSeesANewFileUnderAnOldFolder() throws {
    let box = try Sandbox()
    defer { box.remove() }
    let cache = try box.folder("cache")
    try box.file("cache/deep/index.db", modified: .now)
    try FileManager.default.setAttributes([.modificationDate: daysAgo(200)], ofItemAtPath: cache.path)

    let facts = TreeWalk.inspect(cache)
    #expect(facts.isComplete)
    #expect(try #require(facts.idle(at: .now)) < 60)
}

@Test func treeWalkWithAnUnreadableFolderCannotTell() throws {
    let box = try Sandbox()
    defer { box.remove() }
    try box.file("cache/old.bin", modified: daysAgo(100))
    let locked = try box.folder("cache/locked")
    try box.file("cache/locked/new.bin", modified: .now)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

    let facts = TreeWalk.inspect(box.root.appending(path: "cache"))
    #expect(!facts.isComplete)
    #expect(facts.idle(at: .now) == nil)
}

@Test func treeWalkOverItsBudgetCannotTell() throws {
    let box = try Sandbox()
    defer { box.remove() }
    try box.file("cache/a.bin", modified: daysAgo(100))

    let facts = TreeWalk.inspect(box.root.appending(path: "cache"), budget: .zero)
    #expect(facts.gap == "시간 초과")
    #expect(facts.idle(at: .now) == nil)
}

@Test func treeWalkDoesNotFollowLinks() throws {
    let box = try Sandbox()
    defer { box.remove() }
    try box.file("cache/old.bin", modified: daysAgo(100))
    let outside = try box.folder("outside")
    try box.file("outside/fresh.bin", modified: .now)
    _ = try box.link("cache/elsewhere", to: outside)

    let facts = TreeWalk.inspect(box.root.appending(path: "cache"))
    #expect(facts.isComplete)
    #expect(facts.files == 1)
    #expect(try #require(facts.idle(at: .now)) > 90 * 86_400)
}

@Test func treeWalkOfAnEmptyFolderCannotTell() throws {
    let box = try Sandbox()
    defer { box.remove() }
    #expect(TreeWalk.inspect(try box.folder("empty")).idle(at: .now) == nil)
}

// MARK: - Open files

func lsofOutput(_ names: [String], status: Int32 = 0, filler: Int = OpenFiles.minimumLines) -> Command.Output {
    let lines = ["p1"] + Array(repeating: "n/System/Library/filler", count: filler) + names.map { "n" + $0 }
    return Command.Output(status: status, stdout: Data(lines.joined(separator: "\n").utf8))
}

@Test func openFilesFromAFailedOrShortRunAreUnknown() {
    #expect(OpenFiles.parse(lsofOutput(["/a/b/c"], status: 1)) == nil)
    #expect(OpenFiles.parse(lsofOutput(["/a/b/c"], filler: 10)) == nil)
}

/// Macbak's own walks hold folders open; neither this process nor another copy of Macbak (a measurement copy,
/// `--scan-report`) is anyone using a cache. On 2026-11-04 the app's own scan made 7 build caches read "지금 쓰는 파일이 있습니다".
@Test func macbaksOwnOpenFilesDoNotMarkACacheInUse() {
    let lines = ["p\(getpid())", "cMacbakPackageTests", "n/a/own", "p2", "cMacbak", "n/a/copy", "p3", "cXcode", "n/a/xcode"]
        + Array(repeating: "n/System/Library/filler", count: OpenFiles.minimumLines)
    let open = OpenFiles.parse(Command.Output(status: 0, stdout: Data(lines.joined(separator: "\n").utf8)))
    #expect(open?.anyOpen(under: "/a/own") == false)
    #expect(open?.anyOpen(under: "/a/copy") == false)
    #expect(open?.anyOpen(under: "/a/xcode") == true)
}

@Test func openFilesMatchWholePathComponents() throws {
    let open = try #require(OpenFiles.parse(lsofOutput(["/a/b-old/x", "/q/r", "/Users/Me/Cache/F.db"])))
    #expect(!open.anyOpen(under: "/a/b"))
    #expect(open.anyOpen(under: "/a/b-old"))
    #expect(open.anyOpen(under: "/q/r"))
    #expect(!open.anyOpen(under: "/q/rs"))
    // Case-folded: on APFS these name the same file, and the error is on the side of keeping it.
    #expect(open.anyOpen(under: "/users/me/cache"))
}

// MARK: - Path guard

private struct GuardCase {
    let box: Sandbox
    let root: URL
    let home: URL

    init() throws {
        box = try Sandbox()
        home = box.root
        root = try box.folder("Caches")
    }

    func check(_ target: URL, identity: FileIdentity?? = .none, roots: [URL]? = nil, forbidden: [URL] = [],
               mounts: [String]? = []) -> PathGuard.Refusal? {
        let id = identity ?? FileIdentity.of(target.path)
        return PathGuard.check(target, inside: root, identity: id, allowedRoots: roots ?? [root], forbidden: forbidden, mounts: mounts)
    }
}

@Test func guardAllowsAPlainChildOfTheRoot() throws {
    let g = try GuardCase()
    defer { g.box.remove() }
    #expect(g.check(try g.box.folder("Caches/app")) == nil)
}

@Test func guardRefusesTheRootItself() throws {
    let g = try GuardCase()
    defer { g.box.remove() }
    #expect(g.check(g.root) == .isRoot)
}

@Test func guardRefusesASiblingThatSharesThePrefix() throws {
    let g = try GuardCase()
    defer { g.box.remove() }
    #expect(g.check(try g.box.folder("Caches-old/app")) == .notInsideRoot)
}

@Test func guardRefusesALinkOnTheWay() throws {
    let g = try GuardCase()
    defer { g.box.remove() }
    let outside = try g.box.folder("Documents")
    try g.box.file("Documents/thesis.txt")
    let link = try g.box.link("Caches/app", to: outside)
    #expect(g.check(link.appending(path: "thesis.txt")) == .symbolicLink("app"))
}

@Test func guardRefusesATargetThatIsALink() throws {
    let g = try GuardCase()
    defer { g.box.remove() }
    let link = try g.box.link("Caches/app", to: try g.box.folder("Documents"))
    #expect(g.check(link) == .symbolicLink("app"))
}

@Test func guardRefusesARootThatIsNotAllowed() throws {
    let g = try GuardCase()
    defer { g.box.remove() }
    let other = try g.box.folder("Other")
    #expect(g.check(try g.box.folder("Caches/app"), roots: [other]) == .rootNotAllowed)
}

@Test func guardRefusesAForbiddenFolderAndAnythingHoldingIt() throws {
    let g = try GuardCase()
    defer { g.box.remove() }
    let kept = try g.box.folder("Caches/keep/uv")
    #expect(g.check(kept, forbidden: [kept]) == .forbidden)
    #expect(g.check(try g.box.folder("Caches/keep/uv/archive"), forbidden: [kept]) == .forbidden)
    #expect(g.check(g.box.root.appending(path: "Caches/keep"), forbidden: [kept]) == .forbidden)
}

@Test func guardRefusesAReplacedTarget() throws {
    let g = try GuardCase()
    defer { g.box.remove() }
    let app = try g.box.folder("Caches/app")
    let scanned = FileIdentity.of(app.path)
    try FileManager.default.removeItem(at: app)
    try g.box.folder("Caches/app")
    #expect(g.check(app, identity: .some(scanned)) == .identityChanged)
    #expect(g.check(app, identity: .some(nil)) == .identityChanged)
}

@Test func guardRefusesAFolderHoldingAMountPoint() throws {
    let g = try GuardCase()
    defer { g.box.remove() }
    let app = try g.box.folder("Caches/app")
    #expect(g.check(app, mounts: [app.path + "/volume"]) == .containsMount(app.path + "/volume"))
    #expect(g.check(app, mounts: nil) == .unreadable("마운트 목록"))
}

@Test func guardComparesTheRootExactly() throws {
    let g = try GuardCase()
    defer { g.box.remove() }
    try g.box.folder("Caches/app")
    // Same folder on this case-insensitive volume, but containment is not decided by folding case.
    let otherCase = URL(fileURLWithPath: g.root.deletingLastPathComponent().path + "/caches/app")
    #expect(g.check(otherCase) == .notInsideRoot)
}

@Test func realMountListIsReadable() {
    #expect(PathGuard.mountPoints()?.contains("/") == true)
}

// MARK: - Platform behavior the executor relies on

@Test func removingAFolderRemovesLinksNotWhatTheyPointAt() throws {
    let box = try Sandbox()
    defer { box.remove() }
    let keep = try box.file("Documents/keep.txt")
    try box.file("Caches/app/data.bin")
    _ = try box.link("Caches/app/docs", to: box.root.appending(path: "Documents"))
    _ = try box.link("Caches/app/file", to: keep)

    try FileManager.default.removeItem(at: box.root.appending(path: "Caches/app"))
    #expect(FileManager.default.fileExists(atPath: keep.path))
    #expect(!FileManager.default.fileExists(atPath: box.root.appending(path: "Caches/app").path))
}

@Test func guardRefusesDotDotInsteadOfInterpretingIt() throws {
    let g = try GuardCase()
    defer { g.box.remove() }
    try g.box.folder("Caches/app")
    #expect(g.check(URL(fileURLWithPath: g.root.path + "/app/..")) == .notInsideRoot)
}

// MARK: - AI storage targets

@Test func aiInUseNeedsBothProbesUnlessOneSaysInUse() throws {
    let open = try #require(OpenFiles.parse(lsofOutput(["/cache/claude/log.txt"])))
    #expect(AIStorageRules.inUse(nil, any: ["claude"], openFiles: open, folders: ["/cache/other"]) == nil)
    #expect(AIStorageRules.inUse([], any: ["claude"], openFiles: nil, folders: ["/cache/other"]) == nil)
    #expect(AIStorageRules.inUse(["claude"], any: ["claude"], openFiles: nil, folders: []) == true)
    #expect(AIStorageRules.inUse([], any: ["claude"], openFiles: open, folders: ["/cache/claude"]) == true)
    #expect(AIStorageRules.inUse([], any: ["claude"], openFiles: open, folders: ["/cache/other"]) == false)
}

private func tool(_ areas: [StorageArea]) -> AITool {
    AITool(id: "probe-tool", name: "Probe", vendor: .other, symbol: "cpu", process: ProcessRule(names: ["probe-tool"]), cleanable: areas)
}

@Test func staleAreaListsOnlyOldFilesThatNobodyHasOpen() throws {
    let box = try Sandbox()
    defer { box.remove() }
    let old = try box.file("logs/old.log", bytes: 4096, modified: daysAgo(30))
    let busy = try box.file("logs/busy.log", bytes: 4096, modified: daysAgo(30))
    try box.file("logs/new.log", bytes: 4096, modified: .now)
    let open = try #require(OpenFiles.parse(lsofOutput([busy.path])))
    let area = StorageArea(id: "logs", name: "logs", symbol: "doc", paths: [.home("logs")], kind: .stale(days: 7))

    let report = AIStorageScanner.scan(running: [], openFiles: open, catalog: [tool([area])], shared: [], home: box.root)
    let candidate = try #require(report.candidates.first)
    guard case .removeFiles(let files) = try #require(candidate.targets.first).action else { Issue.record("not a file list"); return }
    #expect(files.map(\.path) == [old.path])
    #expect(candidate.verdict.status == .ready)
}

@Test func cacheAreaWithAnUnreadableItemIsProtected() throws {
    let box = try Sandbox()
    defer { box.remove() }
    try box.file("cache/a/blob.bin", bytes: 4096, modified: daysAgo(30))
    let locked = try box.folder("cache/b")
    try box.file("cache/b/blob.bin", bytes: 4096)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
    let open = try #require(OpenFiles.parse(lsofOutput([])))
    let area = StorageArea(id: "cache", name: "cache", symbol: "doc", paths: [.home("cache")], kind: .cache)

    let report = AIStorageScanner.scan(running: [], openFiles: open, catalog: [tool([area])], shared: [], home: box.root)
    let candidate = try #require(report.candidates.first)
    #expect(candidate.verdict.status == .protected)
    #expect(candidate.lowerBound)
    #expect(!candidate.isSelectable)
}

@Test func rowsWithNothingToDeleteCannotBeTicked() {
    let ready = CleanupCandidate(id: "x", name: "x", detail: "", symbol: "doc", bytes: 1,
                                 evidence: Evidence(verified: true, inUse: false, regenerable: true))
    #expect(ready.verdict.status == .ready)
    #expect(!ready.isSelectable)
    #expect(!ready.isPreselected)
}

@Test func guardRefusesARootThatIsALink() throws {
    let box = try Sandbox()
    defer { box.remove() }
    let documents = try box.folder("Documents")
    let thesis = try box.file("Documents/thesis.txt")
    let linkedRoot = try box.link("Caches", to: documents)
    let target = URL(fileURLWithPath: documents.path + "/thesis.txt")
    #expect(PathGuard.check(target, inside: linkedRoot, identity: FileIdentity.of(thesis.path), allowedRoots: [linkedRoot],
                            forbidden: [], mounts: []) == .rootIsLinked)
    #expect(ScanSupport.resolved(box.root, "Caches") == nil)
    #expect(ScanSupport.resolved(box.root, "Documents") != nil)
}

@Test func confirmedRowsTheLatestScanChangedAreDropped() {
    let target = CleanupTarget(path: URL(fileURLWithPath: "/x/a"), root: URL(fileURLWithPath: "/x"), identity: nil, action: .removeItem)
    let other = CleanupTarget(path: URL(fileURLWithPath: "/x/b"), root: URL(fileURLWithPath: "/x"), identity: nil, action: .removeItem)
    let ready = Evidence(verified: true, inUse: false, regenerable: true)
    func row(_ id: String, _ targets: [CleanupTarget], _ evidence: Evidence = ready) -> CleanupCandidate {
        CleanupCandidate(id: id, name: id, detail: "", symbol: "doc", bytes: 1, evidence: evidence, targets: targets)
    }
    let confirmed = [row("same", [target]), row("protected", [target]), row("moved", [target]), row("gone", [target])]
    let latest = [row("same", [target]), row("protected", [target], Evidence(verified: true, inUse: true, regenerable: true)), row("moved", [other])]
    #expect(CleanupCandidate.stillCurrent(confirmed, in: latest).map(\.id) == ["same"])
}


/// The shape production uses: scanners pass the root already resolved, and the allowed list holds the written path.
/// A configured root that is a link must still be refused.
@Test func guardRefusesAnAllowedRootThatIsALinkWhenGivenItsResolvedPath() throws {
    let box = try Sandbox()
    defer { box.remove() }
    let documents = try box.folder("Documents")
    let thesis = try box.file("Documents/thesis.txt")
    let configured = try box.link("Caches", to: documents)
    #expect(PathGuard.check(URL(fileURLWithPath: documents.path + "/thesis.txt"), inside: documents, identity: FileIdentity.of(thesis.path),
                            allowedRoots: [configured], forbidden: [], mounts: []) == .rootIsLinked)
}

@Test func aiAreaReachedThroughALinkIsSkipped() throws {
    let box = try Sandbox()
    defer { box.remove() }
    let elsewhere = try box.folder("Documents")
    try box.file("Documents/report.pdf", bytes: 4096, modified: daysAgo(30))
    _ = try box.link("cache", to: elsewhere)
    let open = try #require(OpenFiles.parse(lsofOutput([])))
    let area = StorageArea(id: "cache", name: "cache", symbol: "doc", paths: [.home("cache")], kind: .cache)

    let report = AIStorageScanner.scan(running: [], openFiles: open, catalog: [tool([area])], shared: [], home: box.root)
    #expect(report.candidates.isEmpty)
}

@Test func openFilesIgnoreATrailingSlash() throws {
    // `URL.path(percentEncoded:)` ends folder paths in "/"; a shell sitting in the folder shows in `lsof` without one.
    let open = try #require(OpenFiles.parse(lsofOutput(["/Users/me/dev/app"])))
    #expect(open.anyOpen(under: "/Users/me/dev/app/"))
    #expect(!open.anyOpen(under: "/Users/me/dev/ap/"))
}

@Test func buildServerKeyMatchesItsFolderName() {
    #expect(XcodeCacheScanner.buildServerKey(for: "/Users/me/dev/app/x.xcworkspace") == PathKey.fold("-Users-me-dev-app"))
}

/// The AI tool catalog vouches for its caches, but not for what someone put inside: a wallet deep in keeps the row, a
/// document keeps it out of the shallow clean-up.
@Test func aCatalogCacheWithAWalletOrADocumentInsideIsNotShallow() throws {
    let box = try Sandbox()
    defer { box.remove() }
    try box.file("wallet-cache/a/blob.bin", bytes: 4096, modified: daysAgo(30))
    try box.file("wallet-cache/a/b/wallet.dat", bytes: 100, modified: daysAgo(30))
    try box.file("doc-cache/a/blob.bin", bytes: 4096, modified: daysAgo(30))
    try box.file("doc-cache/a/b/report.pdf", bytes: 100, modified: daysAgo(30))
    try box.file("plain-cache/a/blob.bin", bytes: 4096, modified: daysAgo(30))
    let open = try #require(OpenFiles.parse(lsofOutput([])))
    let areas = ["wallet", "doc", "plain"].map { StorageArea(id: $0, name: $0, symbol: "doc", paths: [.home("\($0)-cache")], kind: .cache) }

    let report = AIStorageScanner.scan(running: [], openFiles: open, catalog: [tool(areas)], shared: [], home: box.root)
    let rows = Dictionary(uniqueKeysWithValues: report.candidates.map { ($0.name, $0) })
    #expect(rows["wallet"]?.verdict.status == .protected)
    #expect(rows["doc"]?.isPreselected == true && rows["doc"]?.isShallow == false)
    #expect(rows["plain"]?.isShallow == true)
}
