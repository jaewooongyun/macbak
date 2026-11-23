import Foundation
import SwiftUI
import Testing
@testable import Macbak

private func sampleRow(_ id: String, awaiting: Bool = false, protected: Bool = false) -> CleanupCandidate {
    var evidence = Evidence(verified: true, inUse: false, regenerable: true)
    evidence.awaitingModel = awaiting
    if protected { evidence.protectedReason = "지키는 이유" }
    return CleanupCandidate(id: id, name: id, detail: "", symbol: "folder", bytes: 2_000_000, evidence: evidence,
                            targets: [CleanupTarget(path: URL(fileURLWithPath: "/nonexistent/\(id)/a"), root: URL(fileURLWithPath: "/nonexistent/\(id)"),
                                                    identity: nil, action: .removeItem)])
}

/// Every pattern the immediate clean-up trusts is a developer-table row the rules pre-tick, so the list cannot drift.
@Test func localRebuildRowsAreTableRowsTheRulesTick() {
    let tiers = Dictionary(CacheRules.devTable.map { ($0.0.regex.pattern, $0.1.tier) }, uniquingKeysWith: { first, _ in first })
    for pattern in CacheRules.localRebuild { #expect(tiers[pattern] == .precheck, "\(pattern)") }
}

/// The shallow clean-up takes what comes back by itself: old app caches (Library/Caches, an app's sandbox container, a
/// Chromium app's cache), the developer table's local build caches and old logs. What is downloaded again, an unknown
/// tool's ~/.cache folder and an app cache the rules cannot tell stay in the dashboard.
@Test func onlyVouchedRowsAreShallow() throws {
    let box = try Sandbox()
    defer { box.remove() }
    let old = daysAgo(10)
    try box.file("Library/Caches/go-build/ab/cd", bytes: 2_000_000, modified: old)
    try box.file("Library/Caches/com.example.unknown/store.xyz", bytes: 2_000_000, modified: old)
    try box.file("Library/Logs/OldApp/old.log", bytes: 2_000_000, modified: daysAgo(40))
    try box.file(".gradle/caches/build-cache-1/ab/entry", bytes: 2_000_000, modified: old)
    try box.file(".npm/_cacache/content-v2/sha512/ab/cd", bytes: 2_000_000, modified: old)
    try box.file("Library/Application Support/Chat/Cache/Cache_Data/f_0001", bytes: 2_000_000, modified: old)
    try box.file("Library/Application Support/Chat/Cookies", bytes: 20_000, modified: old)
    try box.file("Library/Application Support/Chat/Preferences", bytes: 2_000, modified: old)
    try box.file("Library/Containers/com.x/Data/Library/Caches/com.x/fsCachedData/a", bytes: 2_000_000, modified: old)
    try box.file(".cache/some-tool/blobs/ab.cache", bytes: 2_000_000, modified: old)
    try box.file("Library/Application Support/com.apple.wallpaper/aerials/videos/a.mov", bytes: 2_000_000, modified: old)
    let context = ScanContext(home: box.root, now: .now, openFiles: OpenFiles.parse(lsofOutput([])), runningBundleIDs: [], installedBundleIDs: [])
    let rows = Dictionary(uniqueKeysWithValues: (AppCacheScanner.scan(context) + GeneralCacheScanner.scan(context)).map { ($0.id, $0) })
    func row(_ id: String) throws -> CleanupCandidate { try #require(rows[id], "\(id) missing; have \(rows.keys.sorted())") }

    #expect(try row("caches.go-build").isShallow)
    #expect(try row("general." + PathKey.fold("Library/Containers/com.x/Data/Library/Caches/com.x")).isShallow)
    #expect(try row("logs.old").isShallow)
    #expect(try row("general." + PathKey.fold(".gradle/caches/build-cache-1")).isShallow)
    #expect(try row("general." + PathKey.fold("Library/Application Support/Chat/Cache")).isShallow)
    // An unknown tool's ~/.cache folder may hold downloads it cannot rebuild: a dashboard tick, not shallow.
    #expect(try !row("general." + PathKey.fold(".cache/some-tool")).isShallow)
    // Ticked in the dashboard, but not shallow: they are downloaded again (a package cache, the system's wallpapers).
    let npm = try row("general." + PathKey.fold(".npm/_cacache"))
    let aerials = try row("general." + PathKey.fold("Library/Application Support/com.apple.wallpaper/aerials"))
    #expect(npm.isPreselected && !npm.isShallow)
    #expect(aerials.isPreselected && !aerials.isShallow)
    // Held for the model's veto, so not yet.
    #expect(try !row("caches." + PathKey.fold("com.example.unknown")).isShallow)
}

/// An app cache the rules cannot tell is held for the on-device model, which may only protect it: an objection keeps it,
/// any other answer lets the 3-day rule tick it again in the dashboard. It never joins the shallow clean-up, which runs
/// without a click: the model can veto, not vouch.
@Test func theModelCanOnlyVetoAnUnknownAppCache() throws {
    let box = try Sandbox()
    defer { box.remove() }
    try box.file("Library/Caches/com.example.unknown/store.xyz", bytes: 2_000_000, modified: daysAgo(10))
    let context = ScanContext(home: box.root, now: .now, openFiles: OpenFiles.parse(lsofOutput([])), runningBundleIDs: [], installedBundleIDs: [])
    let held = try #require(AppCacheScanner.scan(context).first { $0.id == "caches." + PathKey.fold("com.example.unknown") })
    #expect(held.verdict.status == .protected && !held.isSelectable)
    #expect(held.exploreInput?.role == .veto)

    typealias Finding = CacheExplorer.Finding
    for objection in [Finding(offered: false, decision: "regenerable", evidence: "notes.sqlite", warned: true),
                      Finding(offered: false, decision: "userData", evidence: "Documents")] {
        let kept = CleanupCoordinator.applying(objection, to: held)
        #expect(kept.verdict.status == .protected)
        #expect(kept.verdict.reason == "기기 AI가 사용자 데이터나 설정으로 봤습니다.")
    }
    for answer in [Finding(offered: true, decision: "regenerable", evidence: "blobs"),
                   Finding(offered: false, decision: "unknown", evidence: ""),
                   Finding(offered: false, decision: "error", evidence: "")] {
        let released = CleanupCoordinator.applying(answer, to: held)
        #expect(released.isPreselected, "\(answer.decision)")
        #expect(!released.isShallow)
    }
}

/// Without the on-device model nothing will object, so rows held for its veto go back to the person's 3-day rule at once.
@MainActor
@Test func heldRowsAreReleasedWhenTheModelCannotRun() {
    var held = sampleRow("caches.x", awaiting: true)
    held.exploreInput = ExploreInput(url: URL(fileURLWithPath: "/nonexistent/x"), relative: "Library/Caches/x", inside: "a/", beside: "", role: .veto)
    let coordinator = CleanupCoordinator(fixture: [.appCaches: [held]], explorer: CacheExplorer(unavailableBecause: "모델 없음"))
    #expect(coordinator.all.first?.verdict.status == .protected)
    coordinator.startExploring()
    #expect(coordinator.explorer.phase == .unavailable("모델 없음"))
    #expect(coordinator.all.first?.isPreselected == true)
}

/// The dashboard's ticks follow new verdicts on the same rows: a row the model let go is ticked, a row it protected is
/// unticked, and a tick the person removed stays removed.
@Test func ticksFollowNewVerdictsOnTheSameRows() {
    let before = [sampleRow("unticked"), sampleRow("released", awaiting: true), sampleRow("vetoed")]
    let after = [sampleRow("unticked"), sampleRow("released"), sampleRow("vetoed", protected: true)]
    let selected: Set<String> = ["vetoed"]
    let next = CleanupBoard<EmptyView>.reselect(selected, preselectedBefore: CleanupBoard<EmptyView>.preselected(before), rows: after)
    #expect(next == ["released"])
}

@MainActor
private final class Flag {
    var value: Bool
    init(_ value: Bool) { self.value = value }
}

/// A scan asked for while a clean-up deletes waits until the run ends, so no new hold or verdict lands under it.
@MainActor
@Test func aScanWaitsForARunningCleanUp() async {
    let coordinator = CleanupCoordinator(fixture: [:])
    let deleting = Flag(true), done = Flag(false)
    coordinator.isDeleting = { deleting.value }
    let scan = Task { @MainActor in
        await coordinator.scan()
        done.value = true
    }
    try? await Task.sleep(for: .milliseconds(700))
    #expect(!done.value)
    deleting.value = false
    await scan.value
    #expect(done.value)
}

/// A scan waiting for a clean-up whose caller goes away (a screen's task cancelled) gives up instead of spinning.
@MainActor
@Test(.timeLimit(.minutes(1)))
func aCancelledWaitingScanGivesUp() async {
    let coordinator = CleanupCoordinator(fixture: [:])
    coordinator.isDeleting = { true }
    let scan = Task { @MainActor in await coordinator.scan() }
    try? await Task.sleep(for: .milliseconds(300))
    scan.cancel()
    await scan.value
    #expect(scan.isCancelled)
}

/// Homebrew's cache is named after packages; a cask called `poke-token-bar` (this Mac's real case) is not a token. It is
/// a download cache, so a choice.
/// A known store where people put files themselves still keeps a wallet (the measured rules' own boundary case).
@Test func packageNamesAreNotSecretsInHomebrewsCache() throws {
    let box = try Sandbox()
    defer { box.remove() }
    let old = daysAgo(10)
    try box.file("Library/Caches/Homebrew/Cask/poke-token-bar--2.5.6.zip", bytes: 2_000_000, modified: old)
    try box.file("Library/Caches/Homebrew/downloads/0000--wget-1.24.bottle.tar.gz", bytes: 2_000_000, modified: old)
    let context = ScanContext(home: box.root, now: .now, openFiles: OpenFiles.parse(lsofOutput([])), runningBundleIDs: [], installedBundleIDs: [])
    let brew = try #require(AppCacheScanner.scan(context).first { $0.id == "caches.homebrew" })
    #expect(brew.verdict.status == .review)
    #expect(!brew.isShallow)
    let wallet = CacheRules.tier(path: "Library/Application Support/Steam/steamapps/workshop/content", inside: "431960/ (notes.txt, wallet.dat)", beside: "")
    #expect(wallet.tier == .keep)
}

/// The rules read eight names, the deletion takes them all: a wallet past them keeps the whole row, and a document past
/// them keeps the row out of the shallow clean-up (still a dashboard tick).
@Test func aWalletOrADocumentPastTheListingIsSeen() throws {
    let box = try Sandbox()
    defer { box.remove() }
    let old = daysAgo(10)
    for index in 0..<8 { try box.file("Library/Caches/com.example.store/a\(index).cache", bytes: 300_000, modified: old) }
    try box.file("Library/Caches/com.example.store/wallet.dat", bytes: 1_000, modified: old)
    for index in 0..<8 { try box.file("Library/Caches/com.example.docs/a\(index).cache", bytes: 300_000, modified: old) }
    try box.file("Library/Caches/com.example.docs/zz/deep/report.pdf", bytes: 1_000, modified: old)
    try box.file("Library/Caches/com.example.plain/a0.cache", bytes: 2_000_000, modified: old)
    let context = ScanContext(home: box.root, now: .now, openFiles: OpenFiles.parse(lsofOutput([])), runningBundleIDs: [], installedBundleIDs: [])
    let rows = Dictionary(uniqueKeysWithValues: AppCacheScanner.scan(context).map { ($0.id, $0) })
    let wallet = try #require(rows["caches.com.example.store"])
    let docs = try #require(rows["caches.com.example.docs"])
    #expect(wallet.verdict.status == .protected && wallet.verdict.reason.contains("wallet.dat"), "\(wallet.verdict)")
    #expect(docs.isPreselected && !docs.isShallow)
    #expect(try #require(rows["caches.com.example.plain"]).isShallow)
}

/// Build caches go with the shallow clean-up after a day untouched (the person's rule since 2026-11-04); one used within
/// the day is still being worked on.
@Test func buildCachesGoAfterADay() throws {
    let box = try Sandbox()
    defer { box.remove() }
    try box.file("Library/Developer/XcodeBuildMCP/workspaces/w1/test-products/App.xctestproducts/blob", bytes: 2_000_000, modified: daysAgo(2))
    try box.file("Library/Developer/XcodeBuildMCP/workspaces/w2/test-products/App.xctestproducts/blob", bytes: 2_000_000, modified: daysAgo(0.25))
    let context = ScanContext(home: box.root, now: .now, openFiles: OpenFiles.parse(lsofOutput([])), runningBundleIDs: [], installedBundleIDs: [])
    let products = XcodeCacheScanner.scan(context).filter { $0.name.hasPrefix("test-products") }.sorted { ($0.lastUsed ?? .now) < ($1.lastUsed ?? .now) }
    #expect(products.count == 2)
    #expect(products.first?.isShallow == true)
    #expect(products.last?.verdict.status == .protected)
}

/// What an app's build cache really holds must not stop it: a network library's `credentials` folders of C++ code, and the documents
/// SwiftPM checked out with packages, proven by git to be what the fetched history holds. A secret file in a
/// `credentials` folder, a `credentials` file, a file changed, added or committed only in the checkout, and a document
/// outside the checkouts still keep or hold back the row.
@Test func packageFilesInABuildCacheAreNeitherSecretsNorDocuments() async throws {
    let box = try Sandbox()
    defer { box.remove() }
    let dd = "Library/Developer/Xcode/DerivedData/"
    let netLib = "SourcePackages/artifacts/netkit-binary/netkit.xcframework/ios-arm64/netkit.framework/PrivateHeaders/src/core/lib/security/credentials/"
    let pkg = "SourcePackages/checkouts/store-core/"
    func git(_ folder: String, _ arguments: [String]) {
        let options = ["-C", box.root.appending(path: dd + folder + "/" + pkg).path, "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false",
                       "-c", "user.name=t", "-c", "user.email=t@t"]
        #expect(Command.run("/usr/bin/git", options + arguments, timeout: .seconds(30))?.status == 0)
    }
    // A checkout as SwiftPM leaves it: the package's design note, a Numbers document (a folder) and a test folder's
    // build file, committed and fetched (a remote-tracking ref holds HEAD).
    for cache in ["app-packages", "app-edited", "app-added", "app-local", "app-branch"] {
        try box.file(dd + cache + "/" + pkg + "doc/design.pdf", bytes: 2_000_000)
        try box.file(dd + cache + "/" + pkg + "doc/sheet.numbers/Index.zip")
        try box.file(dd + cache + "/" + pkg + "test/credentials/CMakeLists.txt")
        git(cache, ["init", "-q"])
        git(cache, ["add", "."])
        git(cache, ["commit", "-q", "--no-verify", "-m", "package"])
        git(cache, ["update-ref", "refs/remotes/origin/main", "HEAD"])
    }
    // Edited and committed only here: HEAD is no longer something the package's remote has.
    try box.file(dd + "app-local/" + pkg + "doc/design.pdf", bytes: 2_100_000)
    git("app-local", ["commit", "-q", "--no-verify", "-am", "local"])
    // Edited on a branch made here, then back on the fetched revision: the files match HEAD, the edit lives on the branch.
    git("app-branch", ["checkout", "-q", "-b", "mine"])
    try box.file(dd + "app-branch/" + pkg + "doc/design.pdf", bytes: 2_100_000)
    git("app-branch", ["commit", "-q", "--no-verify", "-am", "mine"])
    git("app-branch", ["checkout", "-q", "-"])
    try box.file(dd + "app-packages/" + netLib + "ssl_credentials.h", bytes: 2_000_000)
    try box.file(dd + "app-edited/" + pkg + "doc/design.pdf", bytes: 2_100_000)
    try box.file(dd + "app-added/" + pkg + "client.p12")
    try box.file(dd + "app-key/Build/Intermediates.noindex/credentials", bytes: 2_000_000)
    try box.file(dd + "app-secret/Build/credentials/service-account.json", bytes: 2_000_000)
    try box.file(dd + "app-report/Build/report.pdf", bytes: 2_000_000)
    // Untouched for two days, git's own files included, so every cache is past the one-day rule.
    for case let url as URL in FileManager.default.enumerator(at: box.root, includingPropertiesForKeys: nil)!.allObjects {
        try FileManager.default.setAttributes([.modificationDate: daysAgo(2)], ofItemAtPath: url.path)
    }
    let context = ScanContext(home: box.root, now: .now, openFiles: OpenFiles.parse(lsofOutput([])), runningBundleIDs: [], installedBundleIDs: [])
    let rows = Dictionary(uniqueKeysWithValues: XcodeCacheScanner.scan(context).map { ($0.name, $0) })
    #expect(rows["app-packages (Xcode)"]?.isShallow == true)
    #expect(rows["app-edited (Xcode)"]?.isShallow == false)
    #expect(rows["app-added (Xcode)"]?.isShallow == false)
    #expect(rows["app-local (Xcode)"]?.isShallow == false)
    #expect(rows["app-branch (Xcode)"]?.isShallow == false)
    #expect(rows["app-key (Xcode)"]?.verdict.status == .protected)
    #expect(rows["app-secret (Xcode)"]?.verdict.status == .protected)
    #expect(rows["app-report (Xcode)"]?.isShallow == false)
    #expect(rows["app-report (Xcode)"]?.isPreselected == true)
    // The walk right before a shallow deletion agrees with the scan.
    #expect(CleanupExecutor.deepRefusal(box.root.appending(path: dd + "app-packages")) == nil)
    for cache in ["app-edited", "app-added", "app-local", "app-branch", "app-key", "app-secret"] {
        #expect(CleanupExecutor.deepRefusal(box.root.appending(path: dd + cache)) != nil, "\(cache)")
    }
    // Every row the scan offers as shallow passes the executor's own checks: the menu never promises what a run skips.
    let executor = CleanupExecutor(dependencies: CleanupExecutor.Dependencies(
        allowedRoots: { CleanupRoots.all(home: box.root) + CleanupRoots.ruleRoots(home: box.root) }, forbidden: CleanupRoots.forbidden(home: box.root),
        openFiles: { OpenFiles.parse(lsofOutput([])) }, mounts: { [] }, simulators: { [] }, deleteSimulator: { _ in false }, freeSpace: { 0 },
        runningBundleIDs: { [] }, runningTools: { [] }, audit: CleanupAudit(url: box.root.appending(path: "audit/log.jsonl"))))
    let offered = rows.values.filter(\.isShallow).map { row in
        var stamped = row
        stamped.scannedAt = .now
        return stamped
    }
    #expect(!offered.isEmpty)
    for verdict in await executor.preflight(offered, shallow: true) { #expect(verdict.refusal == nil, "\(verdict.id): \(verdict.refusal ?? "")") }
}

/// Device symbols untouched for two weeks go with the shallow clean-up; newer ones stay a choice, recent ones protected.
@Test func oldDeviceSupportIsShallow() throws {
    let box = try Sandbox()
    defer { box.remove() }
    let base = "Library/Developer/Xcode/iOS DeviceSupport/"
    try box.file(base + "iPhone15,2 26.0 (23A1)/Symbols/blob", bytes: 2_000_000, modified: daysAgo(20))
    try box.file(base + "iPhone16,1 26.4 (23E1)/Symbols/blob", bytes: 2_000_000, modified: daysAgo(5))
    try box.file(base + "iPhone17,1 27.1 (24A1)/Symbols/blob", bytes: 2_000_000, modified: daysAgo(1))
    try box.file(base + "iPhone14,2 25.0 (22A1)/Symbols/manual.pdf", bytes: 2_000_000, modified: daysAgo(20))
    let context = ScanContext(home: box.root, now: .now, openFiles: OpenFiles.parse(lsofOutput([])), runningBundleIDs: [], installedBundleIDs: [])
    let rows = Dictionary(uniqueKeysWithValues: DeveloperDeviceScanner.scan(context).filter { $0.id.hasPrefix("devicesupport.") }.map { ($0.name, $0) })
    #expect(rows["iOS iPhone15,2 26.0 (23A1) 기기 지원 파일"]?.isShallow == true)
    #expect(rows["iOS iPhone16,1 26.4 (23E1) 기기 지원 파일"]?.verdict.status == .review)
    #expect(rows["iOS iPhone17,1 27.1 (24A1) 기기 지원 파일"]?.verdict.status == .protected)
    #expect(rows["iOS iPhone14,2 25.0 (22A1) 기기 지원 파일"]?.isShallow == false)
}

/// A simulator neither booted nor changed for five days starts ticked on the dashboard; one whose folder a clone wrote
/// into stays a choice. None is ever shallow: whose clone holds data in which folder cannot be read while shut down.
@Test func quietSimulatorsAreTickedButNeverShallow() throws {
    let box = try Sandbox()
    defer { box.remove() }
    func device(_ name: String, state: String = "Shutdown", booted: Double, changed: Double) throws -> SimulatorList.Device {
        let data = try box.file("Library/Developer/CoreSimulator/Devices/\(name)/data/Library/blob", bytes: 2_000_000, modified: daysAgo(changed))
        return SimulatorList.Device(udid: name, name: name, runtime: "iOS 27.0", state: state,
                                    dataPath: data.deletingLastPathComponent().deletingLastPathComponent().path(percentEncoded: false),
                                    dataBytes: 2_000_000, lastUsed: daysAgo(booted))
    }
    let devices = [try device("quiet", booted: 10, changed: 10), try device("clone-fed", booted: 10, changed: 0.1),
                   try device("recent", booted: 2, changed: 2), try device("booted", state: "Booted", booted: 10, changed: 10)]
    let context = ScanContext(home: box.root, now: .now, openFiles: OpenFiles.parse(lsofOutput([])), runningBundleIDs: [], installedBundleIDs: [])
    let rows = Dictionary(uniqueKeysWithValues: DeveloperDeviceScanner.simulators(devices, context).map { ($0.name, $0) })
    #expect(rows["quiet 시뮬레이터 (iOS 27.0)"]?.isPreselected == true)
    #expect(rows["clone-fed 시뮬레이터 (iOS 27.0)"]?.verdict.status == .review)
    #expect(rows["recent 시뮬레이터 (iOS 27.0)"]?.verdict.status == .review)
    #expect(rows["booted 시뮬레이터 (iOS 27.0)"]?.verdict.status == .protected)
    #expect(rows.values.allSatisfy { !$0.isShallow })
}

/// Old logs are listed file by file and go with the shallow clean-up, so a log folder holding a key or a document, old
/// or not, is left out whole, as any other shallow row would be.
@Test func oldLogsLeaveAFolderHoldingAKeyOrADocument() throws {
    let box = try Sandbox()
    defer { box.remove() }
    try box.file("Library/Logs/app/old.log", bytes: 2_000_000, modified: daysAgo(40))
    try box.file("Library/Logs/keys/id_rsa", bytes: 2_000_000, modified: daysAgo(40))
    try box.file("Library/Logs/docs/report.pdf", bytes: 2_000_000, modified: daysAgo(40))
    let context = ScanContext(home: box.root, now: .now, openFiles: OpenFiles.parse(lsofOutput([])), runningBundleIDs: [], installedBundleIDs: [])
    let logs = try #require(AppCacheScanner.scan(context).first { $0.id == "logs.old" })
    var listed: [String] = []
    for target in logs.targets { if case .removeFiles(let files) = target.action { listed += files.map { URL(fileURLWithPath: $0.path).lastPathComponent } } }
    #expect(listed == ["old.log"])
    #expect(logs.isShallow)
}

/// The AI storage scan waits while a clean-up deletes, as the disk scan does; one that read folders before a deletion and
/// reported after it put deleted rows back on the lists. A caller that gives up stops waiting.
@MainActor
@Test func theAIStorageScanWaitsForARunningCleanUp() async throws {
    let storage = AIStorage()
    storage.isDeleting = { true }
    let waiting = Task { await storage.scan(using: AIMonitor()) }
    try await Task.sleep(for: .milliseconds(600))
    #expect(!storage.scanning && storage.report == nil)
    waiting.cancel()
    await waiting.value
    #expect(storage.report == nil)
}

/// A command past its deadline returns nil at about the deadline, even when it ignores SIGTERM or leaves a child holding
/// its output open; waiting for the pipe or the exit once kept a run "정리하는 중" for good.
@Test func aCommandPastItsDeadlineReturns() {
    var started = Date.now
    #expect(Command.run("/bin/sh", ["-c", "trap '' TERM; sleep 30"], timeout: .seconds(1)) == nil)
    #expect(Date.now.timeIntervalSince(started) < 8)
    started = Date.now
    #expect(Command.run("/bin/sh", ["-c", "sleep 30 & echo started"], timeout: .seconds(1)) == nil)
    #expect(Date.now.timeIntervalSince(started) < 8)
    #expect(Command.run("/bin/echo", ["hi"], timeout: .seconds(5)).map { String(decoding: $0.stdout, as: UTF8.self) } == "hi\n")
}

/// Callers that block every thread of the pool while they wait still get their output: the reader does not need one.
@Test func commandsThatFillThePoolStillFinish() async {
    let started = Date.now
    let statuses = await withTaskGroup(of: Int32?.self) { group in
        for _ in 0..<ProcessInfo.processInfo.activeProcessorCount * 2 {
            group.addTask { Command.run("/bin/sleep", ["0.3"], timeout: .seconds(20))?.status }
        }
        return await group.reduce(into: []) { $0.append($1) }
    }
    #expect(statuses.allSatisfy { $0 == 0 })
    #expect(Date.now.timeIntervalSince(started) < 10)
}

/// Homebrew keeps links beside its downloads. A link among a cache folder's entries made the path guard refuse the
/// whole row on every run; links are left out of the targets, and the executor's own checks then pass.
@Test func aLinkAmongACachesEntriesNoLongerBlocksTheRow() async throws {
    let box = try Sandbox()
    defer { box.remove() }
    let download = try box.file("Library/Caches/Homebrew/downloads/abc--x--1.0.tar.gz", bytes: 2_000_000, modified: daysAgo(10))
    _ = try box.link("Library/Caches/Homebrew/x--1.0.tar.gz", to: download)
    let context = ScanContext(home: box.root, now: .now, openFiles: OpenFiles.parse(lsofOutput([])), runningBundleIDs: [], installedBundleIDs: [])
    var brew = try #require(AppCacheScanner.scan(context).first { $0.name.contains("Homebrew") })
    #expect(brew.targets.map(\.path.lastPathComponent) == ["downloads"])
    brew.scannedAt = .now
    let executor = CleanupExecutor(dependencies: CleanupExecutor.Dependencies(
        allowedRoots: { CleanupRoots.all(home: box.root) + CleanupRoots.ruleRoots(home: box.root) }, forbidden: CleanupRoots.forbidden(home: box.root),
        openFiles: { OpenFiles.parse(lsofOutput([])) }, mounts: { [] }, simulators: { [] }, deleteSimulator: { _ in false }, freeSpace: { 0 },
        runningBundleIDs: { [] }, runningTools: { [] }, audit: CleanupAudit(url: box.root.appending(path: "audit/log.jsonl"))))
    #expect(await executor.preflight([brew], shallow: false).first?.refusal == nil)
}

/// Security software is kept everywhere by one list: a log folder the classifier names (Kaspersky here), which the path
/// guard's own short list did not, stays out of the 30-day log clean-up.
@Test func securitySoftwareLogsStayOutOfTheLogCleanUp() throws {
    let box = try Sandbox()
    defer { box.remove() }
    try box.file("Library/Logs/app/old.log", bytes: 2_000_000, modified: daysAgo(40))
    try box.file("Library/Logs/Kaspersky/old.log", bytes: 2_000_000, modified: daysAgo(40))
    let context = ScanContext(home: box.root, now: .now, openFiles: OpenFiles.parse(lsofOutput([])), runningBundleIDs: [], installedBundleIDs: [])
    let logs = try #require(AppCacheScanner.scan(context).first { $0.id == "logs.old" })
    #expect(logs.targets.map(\.path.lastPathComponent) == ["app"])
    #expect(CleanupRoots.isManagedSoftware("Library/Logs/Kaspersky"))
}

/// A clean-up does not wait for the AI storage scan (most of a minute). A row it deleted while that scan was reading
/// stays off the lists when the scan's report lands, instead of coming back with its old size.
@MainActor
@Test func rowsDeletedDuringAnAIStorageScanStayDeleted() async throws {
    let storage = AIStorage()
    let gate = DispatchSemaphore(value: 0)
    let rows = ["a", "b"].map { CleanupCandidate(id: $0, name: $0, detail: "", symbol: "doc", bytes: 1, evidence: Evidence(verified: true, inUse: false, regenerable: true), targets: []) }
    storage.read = { _, _ in
        gate.wait()
        return AIStorageReport(totals: [], candidates: rows, scannedAt: .now, duration: 0)
    }
    let scan = Task { await storage.scan(using: AIMonitor()) }
    while !storage.scanning { try await Task.sleep(for: .milliseconds(20)) }
    storage.forget(["a"])
    gate.signal()
    await scan.value
    #expect(storage.report?.candidates.map(\.id) == ["b"])
}
