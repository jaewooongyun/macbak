import Foundation
import Testing
@testable import Macbak

/// A package checkout in one build cache that borrowed its objects from another build cache, which was then deleted —
/// made with git the way SwiftPM makes it: a mirror of the package in each cache, the checkout a shared clone of the
/// lender's mirror.
@Suite struct BrokenCheckoutTests {
    struct Fixture {
        let box: Sandbox
        let borrower: URL
        let lender: URL
        let alarm: URL
        let document: URL
        var mirror: URL { borrower.appending(path: "SourcePackages/repositories/store-core-1a2b") }
        var lenderObjects: URL { lender.appending(path: "SourcePackages/repositories/store-core-1a2b/objects") }

        func context() -> ScanContext {
            ScanContext(home: box.root, now: .now, openFiles: OpenFiles.parse(lsofOutput([])), runningBundleIDs: [], installedBundleIDs: [])
        }
    }

    private static func git(_ arguments: [String], in folder: URL? = nil) throws {
        var options = ["-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", "-c", "user.name=t", "-c", "user.email=t@t",
                       "-c", "init.defaultBranch=main"]
        if let folder { options = ["-C", folder.path(percentEncoded: false)] + options }
        let output = Command.run("/usr/bin/git", options + arguments, timeout: .seconds(30))
        try #require(output?.status == 0, "git \(arguments.joined(separator: " "))")
    }

    static func make(workspace: String? = nil) throws -> Fixture {
        let box = try Sandbox()
        let root = URL(fileURLWithPath: PathGuard.realPath(box.root)!)
        let caches = "Library/Developer/Xcode/DerivedData/"
        let work = root.appending(path: "work")
        try box.file("work/test/credentials/CMakeLists.txt", bytes: 2_000)
        try box.file("work/doc/design.pdf", bytes: 2_000_000)
        try git(["init", "-q"], in: work)
        try git(["add", "."], in: work)
        try git(["commit", "-q", "--no-verify", "-m", "package"], in: work)
        let borrower = root.appending(path: caches + "app-borrower")
        let lender = root.appending(path: caches + "app-lender")
        for cache in [borrower, lender] {
            try git(["clone", "-q", "--mirror", work.path(percentEncoded: false),
                     cache.appending(path: "SourcePackages/repositories/store-core-1a2b").path(percentEncoded: false)])
        }
        let checkout = borrower.appending(path: "SourcePackages/checkouts/store-core")
        try git(["clone", "-q", "--shared", lender.appending(path: "SourcePackages/repositories/store-core-1a2b").path(percentEncoded: false),
                 checkout.path(percentEncoded: false)])
        if let workspace {
            let plist = try PropertyListSerialization.data(fromPropertyList: ["WorkspacePath": workspace], format: .xml, options: 0)
            try plist.write(to: borrower.appending(path: "info.plist"))
        }
        try FileManager.default.removeItem(at: lender)
        try FileManager.default.removeItem(at: work)
        for case let url as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!.allObjects {
            try FileManager.default.setAttributes([.modificationDate: daysAgo(2)], ofItemAtPath: url.path)
        }
        return Fixture(box: box, borrower: borrower, lender: lender, alarm: checkout.appending(path: "test/credentials/CMakeLists.txt"),
                       document: checkout.appending(path: "doc/design.pdf"))
    }

    // MARK: The proof

    @Test func aBrokenCheckoutIsProvenAgainOnlyWhenAsked() throws {
        let f = try Self.make()
        defer { f.box.remove() }
        #expect(!PackageCheckout.isPristine(f.alarm))
        #expect(PackageCheckout.isPristine(f.alarm, reprove: true))
        #expect(PackageCheckout.isPristine(f.document, reprove: true))
        // The usual predicates answer as before; only their re-proving siblings change.
        #expect(CacheRules.isAlarmName(f.alarm, isFolder: false) == CacheRules.isAlarmName(f.alarm, isFolder: false, reprove: false))
        #expect(CacheRules.isAlarmName(f.alarm, isFolder: false))
        #expect(!CacheRules.isAlarmName(f.alarm, isFolder: false, reprove: true))
        #expect(CacheRules.blocksShallow(f.document))
        #expect(!CacheRules.blocksShallow(f.document, reprove: true))
    }

    @Test func withoutTheSameObjectsInItsOwnCacheItStaysUnproven() throws {
        let f = try Self.make()
        defer { f.box.remove() }
        try FileManager.default.removeItem(at: f.mirror)
        #expect(!PackageCheckout.isPristine(f.alarm, reprove: true))
    }

    @Test func objectsThatBorrowThemselvesAreNotUsed() throws {
        let f = try Self.make()
        defer { f.box.remove() }
        try "/somewhere/else/objects\n".write(to: f.mirror.appending(path: "objects/info/alternates"), atomically: true, encoding: .utf8)
        #expect(!PackageCheckout.isPristine(f.alarm, reprove: true))
    }

    @Test func anEditedFileIsNotProven() throws {
        let f = try Self.make()
        defer { f.box.remove() }
        try "changed".write(to: f.alarm, atomically: true, encoding: .utf8)
        #expect(!PackageCheckout.isPristine(f.alarm, reprove: true))
    }

    @Test func aBorrowedFolderStillThereIsNotWorkedAround() throws {
        let f = try Self.make()
        defer { f.box.remove() }
        try FileManager.default.createDirectory(at: f.lenderObjects, withIntermediateDirectories: true)
        #expect(!PackageCheckout.isPristine(f.alarm, reprove: true))
    }

    @Test func aLinkedReplacementIsNotFollowed() throws {
        let f = try Self.make()
        defer { f.box.remove() }
        let elsewhere = f.box.root.appending(path: "elsewhere")
        try FileManager.default.moveItem(at: f.mirror, to: elsewhere)
        try FileManager.default.createSymbolicLink(at: f.mirror, withDestinationURL: elsewhere)
        #expect(!PackageCheckout.isPristine(f.alarm, reprove: true))
    }

    // MARK: The row

    @Test func theScannerRebuildsTheRowAsAChoiceOnly() throws {
        let f = try Self.make()
        defer { f.box.remove() }
        let usual = try #require(XcodeCacheScanner.scan(f.context()).first { $0.name.hasPrefix("app-borrower") })
        #expect(usual.verdict.status == .protected)
        let proven = try #require(XcodeCacheScanner.scan(f.context(), only: [f.borrower.path(percentEncoded: false)], reprove: true).first)
        #expect(proven.id == usual.id && proven.targets == usual.targets)
        #expect(proven.isSelectable && proven.manualOnly && proven.reproved)
        #expect(!proven.isPreselected && !proven.isShallow)
    }

    @Test func theWholeWorkspaceGroupComesBackWithItsOwnProtection() throws {
        let workspace = "/nonexistent/App/App.xcodeproj"
        let f = try Self.make(workspace: workspace)
        defer { f.box.remove() }
        // Another build cache of the same workspace, written just now.
        let other = f.borrower.deletingLastPathComponent().appending(path: "app-other")
        try f.box.file("Library/Developer/Xcode/DerivedData/app-other/Build/blob", bytes: 2_000_000)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["WorkspacePath": workspace], format: .xml, options: 0)
        try plist.write(to: other.appending(path: "info.plist"))
        let proven = try #require(XcodeCacheScanner.scan(f.context(), only: [f.borrower.path(percentEncoded: false)], reprove: true).first)
        #expect(proven.targets.count == 2)
        #expect(proven.verdict.status == .protected && proven.evidence.recentlyUsed)
    }

    // MARK: Running commands

    @Test func anEnvironmentIsAddedToTheInheritedOne() throws {
        let plain = try #require(Command.run("/usr/bin/env", [], timeout: .seconds(5)))
        let added = try #require(Command.run("/usr/bin/env", [], timeout: .seconds(5), environment: ["MACBAK_TEST_VALUE": "1"]))
        let plainText = String(decoding: plain.stdout, as: UTF8.self), addedText = String(decoding: added.stdout, as: UTF8.self)
        #expect(!plainText.contains("MACBAK_TEST_VALUE") && plainText.contains("PATH="))
        #expect(addedText.contains("MACBAK_TEST_VALUE=1") && addedText.contains("PATH="))
    }

    @Test func failuresAndStatusesAreKept() {
        #expect(Command.run("/nonexistent/tool", [], timeout: .seconds(5)) == nil)
        #expect(Command.run("/usr/bin/false", [], timeout: .seconds(5))?.status == 1)
    }

    @Test func tooMuchOutputStopsTheCommandInTime() {
        let started = Date.now
        #expect(Command.run("/usr/bin/yes", [], timeout: .seconds(20), maxBytes: 10_000) == nil)
        #expect(Date.now.timeIntervalSince(started) < 10)
        #expect(Command.run("/bin/echo", ["short"], timeout: .seconds(5), maxBytes: 10_000)?.status == 0)
    }
}
