import Foundation
import Sparkle
import Testing
@testable import Macbak

private var configured: [String: Any] { ["SUFeedURL": "https://example.com/appcast.xml", "SUPublicEDKey": "key"] }

private func isOff(_ availability: UpdaterAvailability) -> Bool {
    if case .off(let reason) = availability { return !reason.isEmpty }
    return false
}

@Test func updaterStartsOnlyInsideAConfiguredBundle() {
    let decide = UpdaterAvailability.decide
    #expect(decide("/Applications/Macbak.app", configured, false) == .on)
    // An app installed on a writable external disk still updates; only a read-only volume stops it.
    #expect(decide("/Volumes/Work/Applications/Macbak.app", configured, false) == .on)

    #expect(isOff(decide("/Users/someone/macbak/.build/out/Products/Debug", configured, false)))
    #expect(isOff(decide("/Applications/Macbak.app", [:], false)))
    #expect(isOff(decide("/Applications/Macbak.app", ["SUFeedURL": "https://example.com/appcast.xml"], false)))
    #expect(isOff(decide("/Applications/Macbak.app", ["SUPublicEDKey": "key"], false)))
    #expect(isOff(decide("/Applications/Macbak.app", ["SUFeedURL": "", "SUPublicEDKey": "key"], false)))
    #expect(isOff(decide("/private/var/folders/x/T/AppTranslocation/1234/d/Macbak.app", configured, false)))
    #expect(isOff(decide("/Volumes/Macbak/Macbak.app", configured, true)))
}

/// Sparkle downloads an update into the host's own cache folder; a clean-up while Macbak runs must not take it away.
@Test func ownUpdateDownloadsAreNeverOffered() throws {
    let box = try Sandbox()
    defer { box.remove() }
    try box.file("Library/Caches/local.roomloop.native/org.sparkle-project.Sparkle/Installation/a1/Macbak-0.2.1.dmg",
                 bytes: 3_000_000, modified: daysAgo(10))
    try box.file("Library/Caches/com.example.other/org.sparkle-project.Sparkle/Installation/b2/Other-2.0.dmg",
                 bytes: 3_000_000, modified: daysAgo(10))
    let context = ScanContext(home: box.root, now: .now, openFiles: OpenFiles.parse(lsofOutput([])),
                              runningBundleIDs: ["local.roomloop.native"], installedBundleIDs: [])

    let found = XcodeCacheScanner.scan(context) + AppCacheScanner.scan(context) + DeveloperDeviceScanner.scan(context)
        + GeneralCacheScanner.scan(context)
    // Path components, so a row that would delete the whole cache folder (a parent of the download) counts too.
    func touches(_ name: String) -> [CleanupCandidate] {
        found.filter { candidate in candidate.name == name || candidate.targets.contains { $0.path.pathComponents.contains(name) } }
    }
    let offered: Set<CleanupStatus> = [.ready, .review]
    let own = touches("local.roomloop.native")
    #expect(!own.isEmpty)
    #expect(own.allSatisfy { !offered.contains($0.verdict.status) })
    // What the coordinator does to rows after the scan: an on-device "re-creatable" finding, then the release of rows
    // held for a veto when no model runs. Neither may turn the running app's own download into an offer.
    let recreatable = CacheExplorer.Finding(offered: true, decision: "regenerable", evidence: "blobs")
    let processed = own.map { row in
        var evidence = CleanupCoordinator.applying(recreatable, to: row).evidence
        evidence.awaitingModel = false
        return row.with(evidence: evidence, aiEvidence: nil)
    }
    #expect(processed.allSatisfy { !offered.contains($0.verdict.status) })
    // The same layout under an app that is not running is an ordinary old cache.
    #expect(touches("com.example.other").contains { offered.contains($0.verdict.status) })
}

/// Sparkle's update alert can turn automatic installs on by itself; an open Settings window must show it. Sparkle reports
/// automatic installs as off while automatic checks are off, so checks go on first.
@MainActor @Test func updaterFollowsSettingsChangedOutsideIt() async {
    let defaults = UserDefaults.standard
    let keys = ["SUEnableAutomaticChecks", "SUAutomaticallyUpdate"]
    let before = keys.map { defaults.object(forKey: $0) }
    defer {
        for (key, value) in zip(keys, before) {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
    }
    let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    let sparkle = controller.updater
    let updater = AppUpdater(availability: .on, version: "1 (1)", makeController: { controller })
    func settle(_ done: () -> Bool) async {
        for _ in 0..<50 where !done() { try? await Task.sleep(for: .milliseconds(20)) }
    }

    sparkle.automaticallyChecksForUpdates = true
    sparkle.automaticallyDownloadsUpdates = false
    await settle { updater.automaticallyChecks && !updater.automaticallyInstalls }
    sparkle.automaticallyDownloadsUpdates = true
    #expect(sparkle.automaticallyDownloadsUpdates)
    await settle { updater.automaticallyInstalls }
    #expect(updater.automaticallyInstalls)

    // Turning checks off makes Sparkle report installs as off too; the toggle must follow both.
    sparkle.automaticallyChecksForUpdates = false
    await settle { !updater.automaticallyChecks && !updater.automaticallyInstalls }
    #expect(!updater.automaticallyChecks)
    #expect(!updater.automaticallyInstalls)
}

@MainActor @Test func updaterCreatesControllerOnlyWhenEnabled() {
    var made = 0
    let make = {
        made += 1
        return SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    }

    let off = AppUpdater(availability: .off("직접 빌드한 앱"), version: "1 (1)", makeController: make)
    #expect(made == 0)
    #expect(off.disabledReason == "직접 빌드한 앱")
    #expect(!off.canCheck)

    let on = AppUpdater(availability: .on, version: "1 (1)", makeController: make)
    #expect(made == 1)
    #expect(on.disabledReason == nil)

    let snapshot = AppUpdater.disabled(reason: "미리 보기")
    #expect(made == 1)
    #expect(!snapshot.canCheck)
    #expect(snapshot.disabledReason == "미리 보기")
}
