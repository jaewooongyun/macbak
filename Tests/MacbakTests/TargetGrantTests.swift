import Foundation
import Testing
@testable import Macbak

/// A folder outside every allowed root, deleted only as itself (`PathGuard.checkExact`) once its grant is judged again
/// by the one function the scan row used; and the build outputs git ignores in a project, found by name and marker.
@Suite struct TargetGrantTests {
    // MARK: The exact check

    static func exact(_ target: URL, grant: URL, identity: FileIdentity?, home: URL, forbidden: [URL] = [], mounts: [String]? = []) -> PathGuard.Refusal? {
        PathGuard.checkExact(target, grant: grant, identity: identity, home: home, forbidden: forbidden, mounts: mounts)
    }

    @Test func onlyTheGrantedFolderItselfPasses() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let folder = try box.folder("dev/app/build")
        let child = try box.folder("dev/app/build/inner")
        let sibling = try box.folder("dev/app/target")
        let identity = FileIdentity.of(folder.path)
        #expect(Self.exact(folder, grant: folder, identity: identity, home: box.root) == nil)
        for other in [sibling, folder.deletingLastPathComponent(), child] {
            #expect(Self.exact(other, grant: folder, identity: FileIdentity.of(other.path), home: box.root) == .notGranted)
        }
        let outside = try Sandbox()
        defer { outside.remove() }
        let away = try outside.folder("app/build")
        #expect(Self.exact(away, grant: away, identity: FileIdentity.of(away.path), home: box.root) == .notInsideRoot)
    }

    @Test func aLinkForbiddenPlaceMountOrChangeOnTheWayRefuses() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let real = try box.folder("real/app/build")
        _ = try box.link("dev", to: box.root.appending(path: "real"))
        let linked = box.root.appending(path: "dev/app/build")
        #expect(Self.exact(linked, grant: linked, identity: FileIdentity.of(real.path), home: box.root) == .symbolicLink("dev"))

        let folder = try box.folder("work/app/build")
        let identity = FileIdentity.of(folder.path)
        #expect(Self.exact(folder, grant: folder, identity: identity, home: box.root, forbidden: [box.root.appending(path: "work")]) == .forbidden)
        let managed = try box.folder("work/zscaler/build")
        #expect(Self.exact(managed, grant: managed, identity: FileIdentity.of(managed.path), home: box.root) == .forbidden)
        #expect(Self.exact(folder, grant: folder, identity: identity, home: box.root, mounts: [folder.path + "/disk"]) == .containsMount(folder.path + "/disk"))
        #expect(Self.exact(folder, grant: folder, identity: identity, home: box.root, mounts: nil) == .unreadable("마운트 목록"))
        try box.file("work/app/build/new")
        #expect(Self.exact(folder, grant: folder, identity: identity, home: box.root) == .identityChanged)
    }

    // MARK: Build outputs git ignores

    static func git(_ arguments: [String], in folder: URL) throws {
        let options = ["-C", folder.path, "-c", "core.hooksPath=/dev/null", "-c", "init.defaultBranch=main"]
        try #require(Command.run("/usr/bin/git", options + arguments, timeout: .seconds(30))?.status == 0, "git \(arguments)")
    }

    static let names = ["gradle/build", "gradle/.gradle", "gradle/.cxx", "rust/target", "swift/.build", "dart/.dart_tool", "next/.next",
                        "turbo/.turbo", "py/__pycache__", "py/.pytest_cache", "py/.mypy_cache", "tox/.tox", "ios/Pods"]

    /// A repository with one project per tool, each with its marker and an output git ignores, 2 MB and five days old,
    /// and outputs that must not be offered: no marker, another tool's marker, `.terraform`, tracked files inside.
    static func repository(_ box: Sandbox) throws -> URL {
        let repo = try box.folder("dev/repo")
        try git(["init", "-q"], in: repo)
        try (["build/", ".gradle/", ".cxx/", "target/", ".build/", ".dart_tool/", ".next/", ".turbo/", "__pycache__/", ".pytest_cache/",
              ".mypy_cache/", ".tox/", "Pods/", ".terraform/"].joined(separator: "\n") + "\n").write(to: repo.appending(path: ".gitignore"), atomically: true, encoding: .utf8)
        for (folder, marker) in [("gradle", "build.gradle"), ("rust", "Cargo.toml"), ("swift", "Package.swift"), ("dart", "pubspec.yaml"),
                                 ("next", "package.json"), ("turbo", "turbo.json"), ("py", "pyproject.toml"), ("tox", "tox.ini"),
                                 ("ios", "Podfile"), ("other", "package.json"), ("tracked", "build.gradle")] {
            try box.file("dev/repo/\(folder)/\(marker)")
        }
        for name in names + ["nomarker/build", "nomarker/target", "other/target", "infra/.terraform", "tracked/build"] {
            try box.file("dev/repo/\(name)/blob", bytes: 2_000_000, modified: daysAgo(5))
        }
        try git(["add", "-f", "tracked/build/blob"], in: repo)
        return repo
    }

    @Test func onlyAToolsOwnOutputBesideItsMarkerIsOffered() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let repo = try Self.repository(box)
        let found = ProjectDiscovery.walk(home: box.root)
        let rows = ProjectOutputScanner.artifactRows(found.artifacts, context: ProjectDiscoveryTests.context(box.root))
        let offered = Set(rows.filter(\.isSelectable).map { String($0.targets[0].path.path.dropFirst(repo.path.count + 1)) })
        #expect(offered == Set(Self.names))
        for row in rows {
            #expect(row.manualOnly && !row.trusted && !row.isPreselected && !row.isShallow)
            if case .projectArtifact(let project)? = row.targets[0].grant?.kind { #expect(project.path == repo.path) } else { Issue.record("no grant") }
        }
    }

    @Test func aProjectGitCannotListOffersNothing() throws {
        let box = try Sandbox()
        defer { box.remove() }
        try "gitdir: /nonexistent/repo/.git\n".write(to: try box.folder("dev/broken").appending(path: ".git"), atomically: true, encoding: .utf8)
        try box.file("dev/broken/build.gradle")
        try box.file("dev/broken/build/blob", bytes: 2_000_000, modified: daysAgo(5))
        let found = ProjectDiscovery.walk(home: box.root)
        #expect(found.artifacts.isEmpty && found.skipped.contains("git 목록을 못 읽은 프로젝트 1곳"))
    }

    @Test func aBuildCacheInsideAnIgnoredFolderIsTheRowNotTheFolder() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let repo = try box.folder("dev/ios")
        try Self.git(["init", "-q"], in: repo)
        try "build/\n".write(to: repo.appending(path: ".gitignore"), atomically: true, encoding: .utf8)
        try box.file("dev/ios/build.gradle")
        let cache = try ProjectDiscoveryTests.derivedData(box, "dev/ios/build/xcode/app")
        let found = ProjectDiscovery.walk(home: box.root)
        #expect(found.derivedData.map(\.path) == [cache.path] && found.artifacts.isEmpty)
    }

    // MARK: One judge

    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func next() -> Int { lock.withLock { count += 1; return count } }
        var total: Int { lock.withLock { count } }
    }

    @Test func theRowTheDeleteAndTheRetryAskTheSameJudge() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let repo = try Self.repository(box)
        let found = ProjectDiscovery.walk(home: box.root).artifacts.filter { $0.folder.lastPathComponent == "target" && $0.folder.path.contains("/rust/") }
        let scanCalls = Calls()
        let rows = ProjectOutputScanner.artifactRows(found, context: ProjectDiscoveryTests.context(box.root)) { grant, inputs in
            _ = scanCalls.next()
            return TargetGrant.evaluate(grant, inputs)
        }
        #expect(scanCalls.total == 1 && rows.count == 1)
        var row = try #require(rows.first)
        row.scannedAt = .now

        // The first delete fails on a file that cannot be removed; the retry's judge then sees a change and refuses.
        let stuck = repo.appending(path: "rust/target/blob")
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: stuck.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: stuck.path) }
        let runCalls = Calls()
        let executor = fixtureExecutor(roots: [], audit: box.root.appending(path: "audit.jsonl")) {
            $0.home = box.root
            $0.judgeGrant = { grant, inputs in
                runCalls.next() == 3 ? ("바뀌었습니다", TreeFacts()) : TargetGrant.evaluate(grant, inputs)
            }
        }
        let report = await executor.run([row]) { _ in }
        #expect(runCalls.total == 3)
        #expect(report.items[0].outcome == .failed("다시 시도하기 전에 바뀌어서 그만둠"))
    }

    /// A build cache the expanded scan found outside the usual places, as the dashboard offers it.
    /// With `repositories`, it holds package mirrors, so the executor reads its borrowers before deleting it.
    static func foundCache(_ box: Sandbox, repositories: Bool = false) throws -> (row: CleanupCandidate, folder: URL) {
        let folder = try ProjectDiscoveryTests.derivedData(box, "dev/app/DerivedData/app-x")
        if repositories {
            try FileManager.default.createDirectory(at: folder.appending(path: "SourcePackages/repositories"), withIntermediateDirectories: true)
            for path in ["SourcePackages/repositories", "SourcePackages", ""] {
                try FileManager.default.setAttributes([.modificationDate: daysAgo(2)], ofItemAtPath: folder.appending(path: path).path)
            }
        }
        var row = try #require(ProjectOutputScanner.rows([folder], context: ProjectDiscoveryTests.context(box.root), lending: .init(), reprove: true).first)
        row.scannedAt = .now
        return (row, folder)
    }

    @Test func aFoundCacheCarriesItsProofModeAndItsWorkspaceFolder() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let row = try Self.foundCache(box).row
        #expect(row.reproved && row.isSelectable)
        #expect(row.guards.watchPaths.map(\.path) == ["/nonexistent/App"])
    }

    @Test func aWorkspaceFileOpenedWhileTheGrantIsJudgedKeepsTheCache() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let (row, folder) = try Self.foundCache(box)
        let calls = Calls(), opened = Calls()
        let quiet = OpenFiles.parse(lsofOutput([])), busy = OpenFiles.parse(lsofOutput(["/nonexistent/App/App.xcodeproj/project.pbxproj"]))
        let executor = fixtureExecutor(roots: [], audit: box.root.appending(path: "audit.jsonl")) {
            $0.home = box.root
            $0.snapshotLifetime = 0.05
            $0.openFiles = { opened.total > 0 ? busy : quiet }
            $0.judgeGrant = { grant, inputs in
                let verdict = TargetGrant.evaluate(grant, inputs)
                // Xcode opens the project during the walk before the delete, a walk longer than an open-file snapshot lives.
                if calls.next() == 2 { _ = opened.next(); Thread.sleep(forTimeInterval: 0.1) }
                return verdict
            }
        }
        let report = await executor.run([row]) { _ in }
        #expect(calls.total == 2 && report.deleted.isEmpty)
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "Build/blob").path))
    }

    /// Opens a workspace file while the borrowers are read after judge call `at`, a read longer than a snapshot lives.
    static func openingWhileBorrowersAreRead(at call: Int, box: Sandbox) -> (inout CleanupExecutor.Dependencies) -> Void {
        let judged = Calls(), opened = Calls()
        let quiet = OpenFiles.parse(lsofOutput([])), busy = OpenFiles.parse(lsofOutput(["/nonexistent/App/App.xcodeproj/project.pbxproj"]))
        return {
            $0.home = box.root
            $0.snapshotLifetime = 0.05
            $0.openFiles = { opened.total > 0 ? busy : quiet }
            $0.judgeGrant = { grant, inputs in
                _ = judged.next()
                return TargetGrant.evaluate(grant, inputs)
            }
            $0.liveBorrowers = { _ in
                if judged.total == call, opened.total == 0 { _ = opened.next(); Thread.sleep(forTimeInterval: 0.1) }
                return []
            }
        }
    }

    @Test func aWorkspaceFileOpenedWhileBorrowersAreReadKeepsTheCache() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let (row, folder) = try Self.foundCache(box, repositories: true)
        #expect(row.isSelectable)
        let executor = fixtureExecutor(roots: [], audit: box.root.appending(path: "audit.jsonl"), change: Self.openingWhileBorrowersAreRead(at: 2, box: box))
        let report = await executor.run([row]) { _ in }
        #expect(report.deleted.isEmpty && FileManager.default.fileExists(atPath: folder.appending(path: "Build/blob").path))
    }

    @Test func aWorkspaceFileOpenedWhileTheRetryReadsBorrowersStopsTheRetry() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let (row, folder) = try Self.foundCache(box, repositories: true)
        // Nothing in it can be removed, so the first delete fails and leaves it exactly as judged (a partial delete
        // would change it, and the retry's judge would refuse for that instead).
        let locked = ["", "Build", "SourcePackages", "SourcePackages/repositories"].map { folder.appending(path: $0).path }
        for path in locked { try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: path) }
        defer { for path in locked { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: path) } }
        let executor = fixtureExecutor(roots: [], audit: box.root.appending(path: "audit.jsonl"), change: Self.openingWhileBorrowersAreRead(at: 3, box: box))
        let report = await executor.run([row]) { _ in }
        #expect(report.items[0].outcome == .failed("다시 시도하기 전에 바뀌어서 그만둠"))
    }

    @Test func settingsChangedWhileTheGrantIsJudgedStopTheDelete() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let (row, folder) = try Self.foundCache(box)
        let calls = Calls(), changed = Calls()
        let executor = fixtureExecutor(roots: [], audit: box.root.appending(path: "audit.jsonl")) {
            $0.home = box.root
            $0.currentAges = { var ages = CleanupAges(); if changed.total > 0 { ages.buildCache = 3 }; return ages }
            $0.judgeGrant = { grant, inputs in
                let verdict = TargetGrant.evaluate(grant, inputs)
                if calls.next() == 2 { _ = changed.next() }   // during the walk right before the delete
                return verdict
            }
        }
        let report = await executor.run([row]) { _ in }
        #expect(calls.total == 2 && report.deleted.isEmpty)
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "Build/blob").path))
    }

    @Test func settingsChangedWhileTheRetryIsJudgedStopTheRetry() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let (row, folder) = try Self.foundCache(box)
        let stuck = folder.appending(path: "Build/blob")
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: stuck.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: stuck.path) }
        let calls = Calls(), changed = Calls()
        let executor = fixtureExecutor(roots: [], audit: box.root.appending(path: "audit.jsonl")) {
            $0.home = box.root
            $0.currentAges = { var ages = CleanupAges(); if changed.total > 0 { ages.buildCache = 3 }; return ages }
            $0.judgeGrant = { grant, inputs in
                let verdict = TargetGrant.evaluate(grant, inputs)
                if calls.next() == 3 { _ = changed.next() }   // during the retry's walk
                return verdict
            }
        }
        let report = await executor.run([row]) { _ in }
        #expect(calls.total == 3)
        #expect(report.items[0].outcome == .failed("다시 시도하기 전에 바뀌어서 그만둠"))
    }

    @Test func aFolderChangedWhileItsGrantIsJudgedIsNotDeleted() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let repo = try Self.repository(box)
        let found = ProjectDiscovery.walk(home: box.root).artifacts.filter { $0.folder.path.hasSuffix("/rust/target") }
        var row = try #require(ProjectOutputScanner.artifactRows(found, context: ProjectDiscoveryTests.context(box.root)).first)
        row.scannedAt = .now
        let target = repo.appending(path: "rust/target")
        let calls = Calls()
        let executor = fixtureExecutor(roots: [], audit: box.root.appending(path: "audit.jsonl")) {
            $0.home = box.root
            $0.judgeGrant = { grant, inputs in
                let verdict = TargetGrant.evaluate(grant, inputs)
                // The walk saw the folder as it was; something lands in it before the judge returns, right before the delete.
                if calls.next() == 2 { try? Data().write(to: target.appending(path: "late")) }
                return verdict
            }
        }
        let report = await executor.run([row]) { _ in }
        #expect(calls.total == 2 && report.deleted.isEmpty)
        #expect(FileManager.default.fileExists(atPath: target.appending(path: "blob").path))
    }

    @Test func aFileWrittenAfterTheScanStopsTheFirstDelete() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let repo = try Self.repository(box)
        try box.file("dev/repo/rust/target/debug/old", modified: daysAgo(5))
        try FileManager.default.setAttributes([.modificationDate: daysAgo(5)], ofItemAtPath: repo.appending(path: "rust/target").path)
        let found = ProjectDiscovery.walk(home: box.root).artifacts.filter { $0.folder.path.hasSuffix("/rust/target") }
        var row = try #require(ProjectOutputScanner.artifactRows(found, context: ProjectDiscoveryTests.context(box.root)).first)
        #expect(row.isSelectable)
        row.scannedAt = .now
        // Deeper than its own entries, so the folder's identity stays the same.
        try box.file("dev/repo/rust/target/debug/new", modified: .now)
        let executor = fixtureExecutor(roots: [], audit: box.root.appending(path: "audit.jsonl")) { $0.home = box.root }
        let report = await executor.run([row]) { _ in }
        #expect(report.items[0].outcome == .skipped("최근에 썼습니다."))
        #expect(FileManager.default.fileExists(atPath: repo.appending(path: "rust/target/debug/old").path))
        let scanned = row
        let shallow = await executor.run([scanned], latest: { _ in scanned }, shallow: true) { _ in }
        #expect(shallow.deleted.isEmpty)
    }

    @Test func aFileGitStartedTrackingAfterTheScanStopsTheDelete() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let repo = try Self.repository(box)
        let found = ProjectDiscovery.walk(home: box.root).artifacts.filter { $0.folder.path.hasSuffix("/swift/.build") }
        var row = try #require(ProjectOutputScanner.artifactRows(found, context: ProjectDiscoveryTests.context(box.root)).first)
        #expect(row.isSelectable)
        row.scannedAt = .now
        try Self.git(["add", "-f", "swift/.build/blob"], in: repo)
        let executor = fixtureExecutor(roots: [], audit: box.root.appending(path: "audit.jsonl")) { $0.home = box.root }
        let report = await executor.run([row]) { _ in }
        #expect(report.items[0].outcome == .skipped("git이 추적하거나 무시하지 않는 폴더입니다"))
        #expect(FileManager.default.fileExists(atPath: repo.appending(path: "swift/.build/blob").path))
    }
}
