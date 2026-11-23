import Foundation
import Testing
@testable import Macbak

/// Build caches that lend package objects to other build caches, made with git the way SwiftPM makes them.
@Suite struct CheckoutAlternatesTests {
    struct World {
        let box: Sandbox
        let root: URL
        let memory: BorrowerMemory
        var derivedData: URL { root.appending(path: "Library/Developer/Xcode/DerivedData") }

        func context() -> ScanContext {
            ScanContext(home: root, now: .now, openFiles: OpenFiles.parse(lsofOutput([])), runningBundleIDs: [], installedBundleIDs: [],
                        borrowerMemory: memory)
        }

        func rows() -> [String: CleanupCandidate] {
            Dictionary(uniqueKeysWithValues: XcodeCacheScanner.scan(context()).map { ($0.name, $0) })
        }

        func executor() -> CleanupExecutor {
            let memory = memory, root = root
            return fixtureExecutor(roots: [derivedData], audit: root.appending(path: "audit.jsonl")) {
                $0.liveBorrowers = { BorrowerMemory.liveBorrowers(of: $0, memory: memory, home: root) }
            }
        }
    }

    private static func git(_ arguments: [String], in folder: URL? = nil) throws {
        var options = ["-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", "-c", "user.name=t", "-c", "user.email=t@t",
                       "-c", "init.defaultBranch=main"]
        if let folder { options = ["-C", folder.path(percentEncoded: false)] + options }
        try #require(Command.run("/usr/bin/git", options + arguments, timeout: .seconds(30))?.status == 0, "git \(arguments)")
    }

    private static func world() throws -> World {
        let box = try Sandbox()
        let root = URL(fileURLWithPath: PathGuard.realPath(box.root)!)
        try box.file("work/Sources/a.swift", bytes: 2_000)
        try git(["init", "-q"], in: root.appending(path: "work"))
        try git(["add", "."], in: root.appending(path: "work"))
        try git(["commit", "-q", "--no-verify", "-m", "p"], in: root.appending(path: "work"))
        return World(box: box, root: root, memory: BorrowerMemory(url: root.appending(path: "support/borrowers.json")))
    }

    /// A build cache with a 2 MB build product and the package's mirror.
    @discardableResult
    private static func cache(_ w: World, _ path: String, workspace: String? = nil) throws -> URL {
        let cache = w.root.appending(path: path)
        try w.box.file(path + "/Build/blob", bytes: 2_000_000, modified: daysAgo(2))
        try git(["clone", "-q", "--mirror", w.root.appending(path: "work").path(percentEncoded: false),
                 cache.appending(path: "SourcePackages/repositories/pkg-1a2b").path(percentEncoded: false)])
        if let workspace {
            let plist = try PropertyListSerialization.data(fromPropertyList: ["WorkspacePath": workspace], format: .xml, options: 0)
            try plist.write(to: cache.appending(path: "info.plist"))
        }
        return cache
    }

    /// A checkout in `borrower` that reads its objects from `lender`'s mirror; returns its alternates file.
    @discardableResult
    private static func borrow(_ borrower: URL, from lender: URL) throws -> String {
        let checkout = borrower.appending(path: "SourcePackages/checkouts/pkg")
        try git(["clone", "-q", "--shared", lender.appending(path: "SourcePackages/repositories/pkg-1a2b").path(percentEncoded: false),
                 checkout.path(percentEncoded: false)])
        return checkout.appending(path: ".git/objects/info/alternates").path(percentEncoded: false)
    }

    private static func age(_ w: World) throws {
        for case let url as URL in FileManager.default.enumerator(at: w.root, includingPropertiesForKeys: nil)!.allObjects
        where !url.path.contains("/support/") {
            try FileManager.default.setAttributes([.modificationDate: daysAgo(2)], ofItemAtPath: url.path)
        }
    }

    private let dd = "Library/Developer/Xcode/DerivedData/"

    @Test func aLenderIsKeptWhileItsBorrowerLivesAndFreedAfter() throws {
        let w = try Self.world()
        defer { w.box.remove() }
        let lender = try Self.cache(w, dd + "app-lender")
        let borrower = try Self.cache(w, dd + "app-borrower")
        try Self.borrow(borrower, from: lender)
        try Self.age(w)
        let rows = w.rows()
        #expect(rows["app-lender (Xcode)"]?.verdict.reason == "다른 캐시 1개가 이 캐시의 패키지 기록을 빌려 씁니다.")
        #expect(rows["app-borrower (Xcode)"]?.verdict.status == .ready)

        try FileManager.default.removeItem(at: borrower)
        #expect(w.rows()["app-lender (Xcode)"]?.verdict.status == .ready)
        #expect(w.memory.load() == .edges([]))
    }

    @Test func theMemoryKeepsALenderSafeFromABorrowerTheUsualScanCannotSee() throws {
        let w = try Self.world()
        defer { w.box.remove() }
        let lender = try Self.cache(w, dd + "app-lender")
        // A build cache outside the usual places, as a project's own DerivedData folder.
        let outside = try Self.cache(w, "dev/app/DerivedData/app-copy")
        let file = try Self.borrow(outside, from: lender)
        try Self.age(w)
        #expect(w.rows()["app-lender (Xcode)"]?.verdict.status == .ready)
        // The expanded scan found it and remembered it; a later process (a restart) reads the file again.
        w.memory.commit(seen: [.init(lender: lender.path(percentEncoded: false), borrower: file)], gone: [])
        let restarted = World(box: w.box, root: w.root, memory: BorrowerMemory(url: w.memory.url))
        #expect(restarted.rows()["app-lender (Xcode)"]?.verdict.status == .protected)
        let stored = try JSONSerialization.jsonObject(with: Data(contentsOf: w.memory.url)) as? [String: Any]
        #expect(stored?["schemaVersion"] as? Int == 1)
    }

    @Test func aRememberedBorrowerIsForgottenOnlyWhenItNoLongerBorrows() throws {
        let w = try Self.world()
        defer { w.box.remove() }
        let lender = try Self.cache(w, dd + "app-lender")
        let a = try Self.borrow(try Self.cache(w, "dev/a/DerivedData/app-a"), from: lender)
        let b = try Self.borrow(try Self.cache(w, "dev/b/DerivedData/app-b"), from: lender)
        let c = try Self.borrow(try Self.cache(w, "dev/c/DerivedData/app-c"), from: lender)
        let key = lender.path(percentEncoded: false)
        let edges: Set<BorrowerMemory.Edge> = [.init(lender: key, borrower: a), .init(lender: key, borrower: b), .init(lender: key, borrower: c)]
        w.memory.commit(seen: edges, gone: [])
        try FileManager.default.removeItem(atPath: a)                                   // gone
        try "/elsewhere/objects\n".write(toFile: b, atomically: true, encoding: .utf8)   // points elsewhere
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: c)   // cannot be read
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: c) }
        try Self.age(w)
        _ = w.rows()
        #expect(w.memory.load() == .edges([.init(lender: key, borrower: c)]))
    }

    @Test func aBorrowerFoundGoneBeforeTheLockButBorrowingAgainIsKept() throws {
        let w = try Self.world()
        defer { w.box.remove() }
        let lender = try Self.cache(w, dd + "app-lender")
        let file = try Self.borrow(try Self.cache(w, "dev/a/DerivedData/app-a"), from: lender)
        let edge = BorrowerMemory.Edge(lender: lender.path(percentEncoded: false), borrower: file)
        w.memory.commit(seen: [edge], gone: [])
        // A scan read the file as gone and stalled; it names the lender again by the time that scan writes.
        w.memory.commit(seen: [], gone: [edge])
        #expect(w.memory.load() == .edges([edge]))
    }

    @Test func aBorrowerBehindAFolderThatCannotBeEnteredIsStillRemembered() throws {
        let w = try Self.world()
        defer { w.box.remove() }
        let lender = try Self.cache(w, dd + "app-lender")
        let file = try Self.borrow(try Self.cache(w, "dev/a/DerivedData/app-a"), from: lender)
        let key = lender.path(percentEncoded: false)
        w.memory.commit(seen: [.init(lender: key, borrower: file)], gone: [])
        let info = (file as NSString).deletingLastPathComponent
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: info)   // stat fails with EACCES, not ENOENT
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: info) }
        #expect(CheckoutAlternates.stillBorrows(file, from: key) == nil)
        try Self.age(w)
        _ = w.rows()
        #expect(w.memory.load() == .edges([.init(lender: key, borrower: file)]))
    }

    @Test func aDamagedMemoryMakesEveryBuildCacheAChoiceAndAMissingOneChangesNothing() throws {
        let w = try Self.world()
        defer { w.box.remove() }
        try Self.cache(w, dd + "app-plain")
        try Self.age(w)
        let plain = try #require(w.rows()["app-plain (Xcode)"])
        #expect(plain.isPreselected && !plain.manualOnly)

        try FileManager.default.createDirectory(at: w.memory.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{\"schemaVersion\": 99, \"edges\": []}".write(to: w.memory.url, atomically: true, encoding: .utf8)
        let held = try #require(w.rows()["app-plain (Xcode)"])
        #expect(held.manualOnly && !held.isPreselected && held.isSelectable)
        // The scan wrote the memory again, so the next one is back to normal.
        #expect(w.memory.load() == .edges([]))
        #expect(try #require(w.rows()["app-plain (Xcode)"]).isPreselected)
    }

    @Test func aBorrowerAddedBetweenScanAndRunStopsTheLendersDeletion() async throws {
        let w = try Self.world()
        defer { w.box.remove() }
        let lender = try Self.cache(w, dd + "app-lender")
        try Self.age(w)
        var row = try #require(w.rows()["app-lender (Xcode)"])
        #expect(row.verdict.status == .ready)
        row.scannedAt = .now
        let file = try Self.borrow(try Self.cache(w, "dev/app/DerivedData/app-copy"), from: lender)
        w.memory.commit(seen: [.init(lender: lender.path(percentEncoded: false), borrower: file)], gone: [])
        let report = await w.executor().run([row]) { _ in }
        #expect(report.items.map(\.outcome) == [.skipped(CleanupExecutor.lenderRefusal)])
        #expect(FileManager.default.fileExists(atPath: lender.path(percentEncoded: false)))
    }

    /// A folder beside the lender whose name differs only in case is another folder on a case-sensitive volume: its
    /// remembered checkout stays a borrower.
    @Test func aBorrowerMatchingOnlyOnceCaseIsFoldedIsKept() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let memory = BorrowerMemory(url: box.root.appending(path: "b.json"))
        let edge = BorrowerMemory.Edge(lender: "/v/dev/Cache", borrower: "/v/dev/cache/DerivedData/App/SourcePackages/checkouts/pkg/.git/objects/info/alternates")
        memory.commit(seen: [edge], gone: [])
        #expect(memory.load() == .edges([edge]))
        #expect(CheckoutAlternates.isInside("/v/dev/Cache/x", "/v/dev/Cache/"))
    }

    @Test func aRowHoldingBothTheLenderAndItsBorrowerIsDeletedWhole() async throws {
        let w = try Self.world()
        defer { w.box.remove() }
        let workspace = "/nonexistent/App/App.xcodeproj"
        let lender = try Self.cache(w, dd + "app-1-lender", workspace: workspace)
        let borrower = try Self.cache(w, dd + "app-2-borrower", workspace: workspace)
        try Self.borrow(borrower, from: lender)
        try Self.age(w)
        var row = try #require(XcodeCacheScanner.scan(w.context()).first)
        #expect(row.verdict.status == .ready)
        row.scannedAt = .now
        let report = await w.executor().run([row]) { _ in }
        #expect(report.items.map(\.outcome.succeeded) == [true])
        #expect(!FileManager.default.fileExists(atPath: lender.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: borrower.path(percentEncoded: false)))
    }

    @Test func insideOneRowTheBorrowerGoesFirstAndALenderWhoseBorrowerStaysIsSkipped() async throws {
        let w = try Self.world()
        defer { w.box.remove() }
        let workspace = "/nonexistent/App/App.xcodeproj"
        let lender = try Self.cache(w, dd + "app-1-lender", workspace: workspace)
        let borrower = try Self.cache(w, dd + "app-2-borrower", workspace: workspace)
        let file = try Self.borrow(borrower, from: lender)
        try Self.age(w)
        var row = try #require(XcodeCacheScanner.scan(w.context()).first)
        #expect(row.verdict.status == .ready)
        #expect(row.targets.map(\.path.lastPathComponent) == ["app-2-borrower", "app-1-lender"])
        row.scannedAt = .now

        // The borrower cannot be deleted: its lender must stay.
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file) }
        let report = await w.executor().run([row]) { _ in }
        #expect(!report.items[0].outcome.succeeded)
        #expect(FileManager.default.fileExists(atPath: lender.path(percentEncoded: false)))
    }

    @Test func aCachesOwnCheckoutIsNeverItsBorrower() async throws {
        let w = try Self.world()
        defer { w.box.remove() }
        // SwiftPM's own checkout reads the same cache's mirror.
        let cache = try Self.cache(w, dd + "app-self")
        let file = try Self.borrow(cache, from: cache)
        try Self.age(w)
        let edge = BorrowerMemory.Edge(lender: cache.path(percentEncoded: false), borrower: file)
        // An older version stored it as a borrower; the scan writes the memory again without it.
        w.memory.commit(seen: [edge], gone: [])
        var row = try #require(w.rows()["app-self (Xcode)"])
        #expect(row.verdict.status == .ready)
        let stored = try JSONSerialization.jsonObject(with: Data(contentsOf: w.memory.url)) as? [String: Any]
        #expect((stored?["edges"] as? [Any])?.isEmpty == true)
        // Stored again between the scan and the run, it still does not keep the cache.
        w.memory.commit(seen: [edge], gone: [])
        row.scannedAt = .now
        let report = await w.executor().run([row]) { _ in }
        #expect(report.items.map(\.outcome.succeeded) == [true])
        #expect(!FileManager.default.fileExists(atPath: cache.path(percentEncoded: false)))
    }

    @Test func theMapNamesCachesWithAFullyBrokenCheckout() throws {
        let w = try Self.world()
        defer { w.box.remove() }
        let lender = try Self.cache(w, dd + "app-lender")
        let borrower = try Self.cache(w, dd + "app-borrower")
        try Self.borrow(borrower, from: lender)
        #expect(XcodeCacheScanner.lendingMap(caches: [borrower, lender], memory: nil).broken.isEmpty)
        try FileManager.default.removeItem(at: lender)
        #expect(XcodeCacheScanner.lendingMap(caches: [borrower], memory: nil).broken == [borrower.path(percentEncoded: false)])
    }

    @Test func commitsFinishingInEitherOrderKeepEachOthersBorrowers() throws {
        let w = try Self.world()
        defer { w.box.remove() }
        let a = BorrowerMemory.Edge(lender: "/l", borrower: "/a"), b = BorrowerMemory.Edge(lender: "/l", borrower: "/b")
        // A scan that read the memory before `a` was added commits after it: `a` stays.
        w.memory.commit(seen: [a], gone: [])
        w.memory.commit(seen: [b], gone: [])
        #expect(w.memory.load() == .edges([a, b]))
        // Only what a scan found gone is dropped.
        w.memory.commit(seen: [], gone: [a])
        #expect(w.memory.load() == .edges([b]))
    }
}
