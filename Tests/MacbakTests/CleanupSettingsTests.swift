import Foundation
import os
import Testing
@testable import Macbak

@MainActor
@Suite struct CleanupSettingsTests {
    private func defaults() -> UserDefaults {
        let name = "macbak.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func context(_ box: Sandbox, _ ages: CleanupAges = CleanupAges()) -> ScanContext {
        ScanContext(home: box.root, now: .now, openFiles: OpenFiles.parse(lsofOutput([])), runningBundleIDs: [], installedBundleIDs: [],
                    ages: ages)
    }

    // MARK: Settings

    @Test func nothingSavedMeansTheStandingRules() {
        let ages = CleanupSettings(defaults: defaults()).ages
        #expect(ages.buildCache == 1 && ages.appCache == 3 && ages.general == 3 && ages.logs == 30)
        #expect(ages.deviceSupportProtect == 3 && ages.deviceSupportShallow == 14 && ages.simulatorQuiet == 5)
        #expect(ages.aiChatLogs == 90 && ages.aiJobScratch == 7 && ages.nodeModules == 60)
        #expect(ages == CleanupAges())
    }

    @Test func aChangeIsSavedAndReadBack() {
        let store = defaults()
        let settings = CleanupSettings(defaults: store)
        settings.set(.buildCache, 3)
        settings.set(.logs, 60)
        let again = CleanupSettings(defaults: store).ages
        #expect(again.buildCache == 3 && again.logs == 60)
        settings.resetToDefaults()
        #expect(CleanupSettings(defaults: store).ages == CleanupAges())
    }

    @Test func valuesOffTheListOrDamagedFallBackToTheDefault() {
        let store = defaults()
        store.set(4, forKey: CleanupAges.Item.buildCache.key)
        store.set("x", forKey: CleanupAges.Item.logs.key)
        store.set(0, forKey: CleanupAges.Item.appCache.key)
        let ages = CleanupSettings(defaults: store).ages
        #expect(ages.buildCache == 1 && ages.logs == 30 && ages.appCache == 3)

        let settings = CleanupSettings(defaults: store)
        settings.set(.appCache, 0)
        settings.set(.logs, 1)
        #expect(settings.ages.appCache == 3 && settings.ages.logs == 30)
        #expect(CleanupAges.Item.allCases.allSatisfy { item in item.choices.allSatisfy { $0 >= 1 } })
    }

    @Test func automaticDeviceSupportCleanUpNeverComesBeforeItsProtectionEnds() {
        let store = defaults()
        let settings = CleanupSettings(defaults: store)
        settings.set(.deviceSupportShallow, 7)
        settings.set(.deviceSupportProtect, 14)
        #expect(settings.ages.deviceSupportShallow == 14)
        store.set(7, forKey: CleanupAges.Item.deviceSupportShallow.key)
        #expect(CleanupSettings(defaults: store).ages.deviceSupportShallow == 14)
    }

    // MARK: Scanners judge by the snapshot

    @Test func buildCachesFollowTheirAge() throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.file("Library/Developer/Xcode/DerivedData/App-abc/Build/blob", bytes: 2_000_000, modified: daysAgo(2))
        let standing = try #require(XcodeCacheScanner.scan(context(box)).first)
        #expect(standing.verdict.status == .ready)
        var three = CleanupAges()
        three.buildCache = 3
        let longer = try #require(XcodeCacheScanner.scan(context(box, three)).first { $0.id == standing.id })
        #expect(longer.verdict.status == .protected && longer.evidence.recentlyUsed)
    }

    @Test func appCachesFollowTheirAge() throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.file("Library/Caches/homebrew/downloads/a.tar.gz", bytes: 2_000_000, modified: daysAgo(2))
        let standing = try #require(AppCacheScanner.scan(context(box)).first { $0.id == "caches.homebrew" })
        #expect(standing.evidence.recentlyUsed && !standing.isSelectable)
        var one = CleanupAges()
        one.appCache = 1
        let shorter = try #require(AppCacheScanner.scan(context(box, one)).first { $0.id == "caches.homebrew" })
        #expect(!shorter.evidence.recentlyUsed && shorter.isSelectable)
    }

    @Test func otherCachesFollowTheirAge() throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.file(".gradle/caches/build-cache-1/ab/entry", bytes: 2_000_000, modified: daysAgo(2))
        let id = "general." + PathKey.fold(".gradle/caches/build-cache-1")
        #expect(try #require(GeneralCacheScanner.scan(context(box)).first { $0.id == id }).evidence.recentlyUsed)
        var one = CleanupAges()
        one.general = 1
        let shorter = try #require(GeneralCacheScanner.scan(context(box, one)).first { $0.id == id })
        #expect(!shorter.evidence.recentlyUsed && shorter.isPreselected)
    }

    @Test func deviceSupportFollowsBothAges() throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.file("Library/Developer/Xcode/iOS DeviceSupport/17.0/Symbols/a", bytes: 2_000_000, modified: daysAgo(10))
        try box.file("Library/Developer/Xcode/iOS DeviceSupport/18.0/Symbols/a", bytes: 2_000_000, modified: daysAgo(2))
        func row(_ version: String, _ ages: CleanupAges) throws -> CleanupCandidate {
            try #require(DeveloperDeviceScanner.scan(context(box, ages)).first { $0.name.contains(version) })
        }
        #expect(try !row("17.0", CleanupAges()).trusted)
        #expect(try row("18.0", CleanupAges()).evidence.recentlyUsed)
        var changed = CleanupAges()
        changed.deviceSupportShallow = 7
        changed.deviceSupportProtect = 1
        #expect(try row("17.0", changed).trusted)
        #expect(try !row("18.0", changed).evidence.recentlyUsed)
    }

    @Test func logsFollowTheirAgeInNameAndCutOff() throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.file("Library/Logs/OldApp/old.log", bytes: 2_000_000, modified: daysAgo(20))
        #expect(!AppCacheScanner.scan(context(box)).contains { $0.id == "logs.old" })
        var fourteen = CleanupAges()
        fourteen.logs = 14
        let logs = try #require(AppCacheScanner.scan(context(box, fourteen)).first { $0.id == "logs.old" })
        #expect(logs.name == "14일 넘은 로그" && logs.detail.contains("14일 넘은 파일"))
    }

    @Test func anOpenFileProtectsWhateverTheAge() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let file = try box.file("Library/Developer/Xcode/DerivedData/App-abc/Build/blob", bytes: 2_000_000, modified: daysAgo(30))
        let open = ScanContext(home: box.root, now: .now, openFiles: OpenFiles.parse(lsofOutput([file.path])), runningBundleIDs: [],
                               installedBundleIDs: [], ages: CleanupAges())
        #expect(try #require(XcodeCacheScanner.scan(open).first).verdict.status == .protected)
    }

    @Test func finishedJobFilesFollowTheirAge() {
        let store = JobStore(root: "jobs")
        #expect(AIStorageRules.jobScratchEvidence(state: "done", store: store, newestFileAge: 5 * 86_400) == nil)
        #expect(AIStorageRules.jobScratchEvidence(state: "done", store: store, newestFileAge: 5 * 86_400, staleAfter: 3 * 86_400) != nil)
    }

    @Test func theMenuHelpSaysTheAgesInUse() {
        var ages = CleanupAges()
        ages.appCache = 5
        ages.buildCache = 2
        ages.deviceSupportShallow = 30
        ages.logs = 60
        let text = MenuBarPanel.shallowHelp(ages)
        #expect(text.contains("5일 넘게 안 쓴 앱 캐시") && text.contains("2일 넘게 안 쓴 Xcode") && text.contains("30일 넘게 안 쓴 기기 지원")
            && text.contains("60일 넘은 로그"))
    }

    // MARK: Stale results

    @Test func aScanCarriesItsAgesAndGoesStaleWhenSettingsChange() async {
        let settings = CleanupSettings(defaults: nil)
        let coordinator = CleanupCoordinator(settings: settings, scanning: .init(
            area: { area, _ in area == .xcode ? [readyRow("x", [])] : [] },
            context: { ages in ScanContext(home: URL(fileURLWithPath: "/nonexistent"), now: .now, openFiles: nil, runningBundleIDs: [],
                                           installedBundleIDs: [], ages: ages) }))
        await coordinator.scan()
        #expect(!coordinator.isStale)
        #expect(coordinator.all.first?.ages == CleanupAges())
        settings.set(.buildCache, 3)
        #expect(coordinator.isStale)
    }

    @Test func aScanThatOutlivesASettingsChangeStaysStale() async {
        let settings = CleanupSettings(defaults: nil)
        let coordinator = CleanupCoordinator(settings: settings, scanning: .init(
            area: { _, _ in [] },
            context: { ages in
                // Settings change after the scan took its snapshot, while it reads.
                settings.set(.buildCache, 3)
                return ScanContext(home: URL(fileURLWithPath: "/nonexistent"), now: .now, openFiles: nil, runningBundleIDs: [],
                                   installedBundleIDs: [], ages: ages)
            }))
        await coordinator.scan()
        #expect(coordinator.scannedAt == nil)
        #expect(coordinator.isStale)
    }

    @Test func anAIStorageScanThatOutlivesASettingsChangeIsDropped() async throws {
        let settings = CleanupSettings(defaults: nil)
        let storage = AIStorage(settings: settings)
        let gate = DispatchSemaphore(value: 0)
        storage.read = { _, ages in
            gate.wait()
            return AIStorageReport(totals: [], candidates: [], scannedAt: .now, duration: 0, ages: ages)
        }
        let scan = Task { await storage.scan(using: AIMonitor()) }
        while !storage.scanning { try await Task.sleep(for: .milliseconds(20)) }
        settings.set(.aiJobScratch, 14)
        gate.signal()
        await scan.value
        #expect(storage.report == nil && storage.isStale)

        storage.read = { _, ages in AIStorageReport(totals: [], candidates: [], scannedAt: .now, duration: 0, ages: ages) }
        await storage.scan(using: AIMonitor())
        #expect(!storage.isStale)
        settings.set(.aiJobScratch, 3)
        #expect(storage.isStale)
    }

    // MARK: The executor

    @Test func rowsJudgedByOtherAgesAreRefusedInEveryRun() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let root = try box.folder("Caches")
        try box.file("Caches/a/blob.bin")
        let row = readyRow("a", [ScanSupport.removal(box.root.appending(path: "Caches/a"), root: root)])
        var now = CleanupAges()
        now.buildCache = 3
        let changed = now
        let executor = fixtureExecutor(roots: [root], audit: box.root.appending(path: "audit.jsonl")) { $0.currentAges = { changed } }
        let picked = await executor.run([row]) { _ in }
        let shallow = await executor.run([row], latest: { _ in row }, shallow: true) { _ in }
        #expect(picked.items.map(\.outcome) == [.skipped(CleanupExecutor.agesRefusal)])
        #expect(shallow.items.map(\.outcome) == [.skipped(CleanupExecutor.agesRefusal)])
        #expect(FileManager.default.fileExists(atPath: box.root.appending(path: "Caches/a/blob.bin").path))
    }

    @Test func agesAreAskedAgainBeforeEachTarget() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let root = try box.folder("Caches")
        try box.file("Caches/a/blob.bin")
        try box.file("Caches/b/blob.bin")
        let row = readyRow("ab", [ScanSupport.removal(box.root.appending(path: "Caches/a"), root: root),
                                  ScanSupport.removal(box.root.appending(path: "Caches/b"), root: root)])
        // The row's check and the first target (asked twice: before its slow checks and right before it goes) see the
        // scan's ages; Settings change before the second target.
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let executor = fixtureExecutor(roots: [root], audit: box.root.appending(path: "audit.jsonl")) { dependencies in
            dependencies.currentAges = {
                let n = calls.withLock { $0 += 1; return $0 }
                var ages = CleanupAges()
                if n > 3 { ages.buildCache = 3 }
                return ages
            }
        }
        let report = await executor.run([row]) { _ in }
        #expect(report.items.map(\.outcome) == [.partial(deleted: 1, of: 2)])
        #expect(!FileManager.default.fileExists(atPath: box.root.appending(path: "Caches/a").path))
        #expect(FileManager.default.fileExists(atPath: box.root.appending(path: "Caches/b/blob.bin").path))
    }

    @Test func agesAreAskedAgainBeforeARetry() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let root = try box.folder("Caches")
        let locked = try box.file("Caches/a/locked.bin")
        // An immutable file makes the first removal fail, so the executor waits and checks again before retrying.
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: locked.path) }
        let row = readyRow("a", [ScanSupport.removal(box.root.appending(path: "Caches/a"), root: root)])
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let executor = fixtureExecutor(roots: [root], audit: box.root.appending(path: "audit.jsonl")) { dependencies in
            dependencies.currentAges = {
                let n = calls.withLock { $0 += 1; return $0 }
                var ages = CleanupAges()
                if n > 3 { ages.buildCache = 3 }
                return ages
            }
        }
        let report = await executor.run([row]) { _ in }
        #expect(report.items.map(\.outcome) == [.failed("다시 시도하기 전에 바뀌어서 그만둠")])
    }
}
