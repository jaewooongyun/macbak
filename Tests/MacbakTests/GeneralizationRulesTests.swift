import Foundation
import Testing
@testable import Macbak

/// Large items of other kinds of work than Apple development, on a made-up home, through the real scanner and the
/// executor's own allowed roots: download and app caches become choices that nothing ticks, and large items a tool must
/// free itself stay protected with that tool's way shown.
@Suite struct GeneralizationRulesTests {
    static let offers = [
        "Library/Application Support/Adobe/Common/Media Cache",
        "Library/Application Support/Epic/UnrealEngine/Common/DerivedDataCache",
        "Library/Unity/Asset Store-5.x",
    ]

    /// A folder's path without the trailing slash a directory URL carries.
    static func folder(_ url: URL) -> String {
        var path = url.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private func home() throws -> Sandbox {
        let box = try Sandbox()
        let old = daysAgo(10)
        try box.file("Library/Application Support/Adobe/Common/Media Cache/clip-a.mcdb", bytes: 2_000_000, modified: old)
        try box.file("Library/Application Support/Epic/UnrealEngine/Common/DerivedDataCache/a/b.udd", bytes: 2_000_000, modified: old)
        try box.file("Library/Unity/Asset Store-5.x/Publisher/Tools/pack.unitypackage", bytes: 2_000_000, modified: old)
        try box.file(".lmstudio/models/community/llama/model.gguf", bytes: 2_000_000, modified: old)
        try box.file("Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw", bytes: 2_000_000, modified: old)
        try box.file(".rustup/toolchains/stable-aarch64-apple-darwin/bin/rustc", bytes: 2_000_000, modified: old)
        try box.file(".android/avd/Pixel_8.avd/config.ini", bytes: 2_000_000, modified: old)
        return box
    }

    private func rows(_ box: Sandbox) -> [String: CleanupCandidate] {
        let context = ScanContext(home: box.root, now: .now, openFiles: OpenFiles.parse(lsofOutput([])), runningBundleIDs: [], installedBundleIDs: [])
        return Dictionary(uniqueKeysWithValues: GeneralCacheScanner.scan(context).map { ($0.id, $0) })
    }

    private func row(_ rows: [String: CleanupCandidate], _ relative: String) -> CleanupCandidate? {
        rows["general." + PathKey.fold(relative)]
    }

    @Test func downloadAndAppCachesOfOtherWorkAreChoicesNothingTicks() throws {
        let box = try home()
        defer { box.remove() }
        let found = rows(box)
        let roots = Set(CleanupRoots.ruleRoots(home: box.root).map(Self.folder))
        for relative in Self.offers {
            let item = try #require(row(found, relative), "\(relative) is listed")
            #expect(item.verdict.status == .review, "\(relative)")
            #expect(!item.targets.isEmpty && item.isSelectable, "\(relative)")
            #expect(!item.isPreselected && !item.isShallow && !item.trusted, "\(relative)")
            #expect(item.exploreInput == nil, "\(relative)")
            #expect(item.evidence.costReason?.isEmpty == false, "\(relative) says what deleting it costs")
            #expect(roots.contains(Self.folder(box.root.appending(path: relative))), "\(relative) is a root the executor accepts")
        }
    }

    @Test func largeItemsAToolFreesItselfStayProtectedWithItsWayShown() throws {
        let box = try home()
        defer { box.remove() }
        let found = rows(box)
        let roots = CleanupRoots.ruleRoots(home: box.root).map(Self.folder)
        let expected: [(String, String?, String)] = [
            ("Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw", "docker system prune", "Docker"),
            (".rustup/toolchains", "rustup toolchain uninstall <이름>", "Rust 툴체인"),
            (".android/avd", nil, "Device Manager"),
            // A model LM Studio imported was moved here: it may be the only copy, so it is never offered.
            (".lmstudio/models", nil, "My Models"),
        ]
        for (relative, command, words) in expected {
            let item = try #require(row(found, relative), "\(relative) is listed")
            #expect(item.verdict.status == .protected, "\(relative)")
            #expect(item.targets.isEmpty && !item.isSelectable, "\(relative)")
            #expect(item.toolCommand == command, "\(relative)")
            #expect(item.verdict.reason.contains(words), "\(relative): \(item.verdict.reason)")
            #expect(item.exploreInput == nil, "\(relative)")
            #expect(!roots.contains { $0.hasPrefix(Self.folder(box.root.appending(path: relative))) }, "\(relative)")
        }
    }

    /// The way shown is words and a command only: the verdict it sits on is the rules' own.
    @Test func theWayShownNeverChangesAVerdict() {
        #expect(CacheRules.reclaimTip(".rustup/toolchains") != nil)
        #expect(CacheRules.tier(path: ".rustup/toolchains", inside: "stable-aarch64-apple-darwin/", beside: "settings.toml").tier == .model)
        #expect(CacheRules.tier(path: "Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw", inside: "", beside: "").tier == .keep)
        #expect(CacheRules.reclaimTip(".rustup/downloads") == nil)
        #expect(CacheRules.reclaimTip("Library/Containers/com.docker.docker/Data/log") == nil)
    }

    /// What else the new places hold is never ticked nor cleaned without a click, whatever the rules call it: a
    /// Chromium cache beside its profile's state and an old cache-named folder would otherwise be.
    @Test func everythingElseTheNewPlacesHoldWaitsForAHandPick() throws {
        let box = try home()
        defer { box.remove() }
        let old = daysAgo(10)
        try box.file("Library/Application Support/Adobe/Common/GPUCache/data_0", bytes: 2_000_000, modified: old)
        try box.file("Library/Application Support/Adobe/Common/Cookies", bytes: 2_000, modified: old)
        try box.file("Library/Application Support/Adobe/Common/Preferences", bytes: 2_000, modified: old)
        try box.file("Library/Unity/cache/packages/a.tgz", bytes: 2_000_000, modified: old)
        try box.file("Library/Application Support/Epic/UnrealEngine/Common/Cache/blob.bin", bytes: 2_000_000, modified: old)
        // The same Chromium cache one level up, where the usual patterns reach it: the existing rule still trusts it.
        try box.file("Library/Application Support/Chat/GPUCache/data_0", bytes: 2_000_000, modified: old)
        try box.file("Library/Application Support/Chat/Cookies", bytes: 2_000, modified: old)
        let found = rows(box)
        let new = found.values.filter { $0.detail.hasPrefix("~/Library/Application Support/Adobe/Common/") || $0.detail.hasPrefix("~/Library/Unity/")
            || $0.detail.hasPrefix("~/Library/Application Support/Epic/") || $0.detail.hasPrefix("~/Library/Containers/com.docker.docker/") }
        #expect(new.count >= 8)
        for item in new {
            #expect(item.manualOnly && !item.isPreselected && !item.isShallow, "\(item.detail)")
        }
        let gpu = try #require(row(found, "Library/Application Support/Adobe/Common/GPUCache"))
        #expect(gpu.isSelectable, "still a choice for a person")
        #expect(try #require(row(found, "Library/Application Support/Chat/GPUCache")).isShallow)
        #expect(GeneralCacheScanner.isHandPicked("Library/Unity/cache") && !GeneralCacheScanner.isHandPicked("Library/Application Support/Adobe/Common"))
    }

    /// A key inside a new offer still keeps the whole row, as everywhere else.
    @Test func aKeyInsideANewOfferKeepsTheRow() throws {
        let box = try home()
        defer { box.remove() }
        try box.file("Library/Unity/Asset Store-5.x/Publisher/id_ed25519", bytes: 400, modified: daysAgo(10))
        let item = try #require(row(rows(box), "Library/Unity/Asset Store-5.x"))
        #expect(item.verdict.status == .protected)
        #expect(item.targets.isEmpty)
    }
}
