import Foundation
import Testing
@testable import Macbak

@MainActor
private final class FakeApp: QuittableApp {
    var bundleIdentifier: String?
    var launchDate: Date?
    var isTerminated = false
    var accepts = true
    var quitsAfterAsking = true
    private(set) var asked = 0

    init(bundle: String, launched: Date) {
        bundleIdentifier = bundle
        launchDate = launched
    }

    func terminate() -> Bool {
        asked += 1
        if accepts, quitsAfterAsking { isTerminated = true }
        return accepts
    }
}

private let launched = Date(timeIntervalSince1970: 1_000)
private let shown = AppMemory(id: 4242, name: "Editor", icon: nil, footprint: 1, bundleID: "com.example.editor", launched: launched)

@MainActor @Test func quitterQuitsTheAppThatWasShown() async {
    let app = FakeApp(bundle: "com.example.editor", launched: launched)
    #expect(await AppQuitter.quit(shown, resolve: { _ in app }, wait: .seconds(1)) == .quit)
    #expect(app.asked == 1)
}

@MainActor @Test func quitterLeavesAProcessThatReusedThePid() async {
    let other = FakeApp(bundle: "com.example.other", launched: launched)
    let relaunched = FakeApp(bundle: "com.example.editor", launched: launched.addingTimeInterval(60))
    #expect(await AppQuitter.quit(shown, resolve: { _ in other }) == .changed)
    #expect(await AppQuitter.quit(shown, resolve: { _ in relaunched }) == .changed)
    #expect(other.asked == 0 && relaunched.asked == 0)
}

@MainActor @Test func quitterReportsADeclineAndAnAppStillAsking() async {
    let declining = FakeApp(bundle: "com.example.editor", launched: launched)
    declining.accepts = false
    #expect(await AppQuitter.quit(shown, resolve: { _ in declining }) == .declined)
    let asking = FakeApp(bundle: "com.example.editor", launched: launched)
    asking.quitsAfterAsking = false
    #expect(await AppQuitter.quit(shown, resolve: { _ in asking }, wait: .zero) == .stillOpen)
}

@MainActor @Test func quitterNeverQuitsItselfOrFinder() async {
    let me = AppMemory(id: ProcessInfo.processInfo.processIdentifier, name: "Macbak", icon: nil, footprint: 1)
    let finder = AppMemory(id: 1, name: "Finder", icon: nil, footprint: 1, bundleID: "com.apple.finder")
    #expect(await AppQuitter.quit(me, resolve: { _ in nil }) == .notAllowed)
    #expect(await AppQuitter.quit(finder, resolve: { _ in nil }) == .notAllowed)
}

@Test func aReusedPidDoesNotCarryTheTick() {
    let editor = AppMemory(id: 77, name: "Editor", icon: nil, footprint: 1, bundleID: "com.example.editor", launched: Date(timeIntervalSince1970: 1))
    let stranger = AppMemory(id: 77, name: "Stranger", icon: nil, footprint: 1, bundleID: "com.example.other", launched: Date(timeIntervalSince1970: 2))
    var picks = AppPicks()
    picks.set(editor, true)
    #expect(picks.contains(editor))
    #expect(!picks.contains(stranger))
}

private let now = Date(timeIntervalSince1970: 1_000_000)
private let start = now.addingTimeInterval(-6 * 3600)

private func app(_ pid: pid_t, _ name: String, windows: Int?, active: Bool = false, bundle: String? = nil) -> AppMemory {
    AppMemory(id: pid, name: name, icon: nil, footprint: UInt64(pid) * 1_000_000, bundleID: bundle ?? "com.example.\(name)",
              launched: start.addingTimeInterval(-3600), isActive: active, windows: windows)
}

@Test func idleAppsLeaveOutWhatIsInUse() {
    let apps = [app(10, "front", windows: 2, active: true), app(11, "recent", windows: 1), app(12, "finder", windows: 1, bundle: "com.apple.finder"),
                app(13, "chat", windows: 0)]
    let lastActive: [pid_t: Date] = [11: now.addingTimeInterval(-10 * 60), 13: now.addingTimeInterval(-10 * 60)]
    #expect(IdleApps.candidates(apps, lastActive: lastActive, trackingSince: start, now: now).isEmpty)
}

@Test func idleAppsPutWindowlessFirstThenTheLongestIdle() {
    let apps = [app(20, "editor", windows: 1), app(21, "chat", windows: 0), app(22, "browser", windows: 3), app(23, "fresh", windows: 1)]
    let lastActive: [pid_t: Date] = [20: now.addingTimeInterval(-2 * 3600), 22: now.addingTimeInterval(-5 * 3600), 23: now.addingTimeInterval(-20 * 60)]
    let found = IdleApps.candidates(apps, lastActive: lastActive, trackingSince: start, now: now)
    #expect(found.map(\.app.name) == ["chat", "browser", "editor"])
    #expect(found[0].reason.hasPrefix("창 없이 실행 중"))
}

@Test func aTickedAppBroughtBackToUseIsNotChosen() {
    let editor = app(30, "editor", windows: 1)
    var picks = AppPicks()
    picks.set(editor, true)
    let idleBefore = IdleApps.candidates([editor], lastActive: [30: now.addingTimeInterval(-2 * 3600)], trackingSince: start, now: now)
    #expect(picks.chosen(from: idleBefore).map(\.id) == [30])
    // Brought to the front after it was ticked: no longer unused, so the tick must not quit it.
    let idleAfter = IdleApps.candidates([editor], lastActive: [30: now.addingTimeInterval(-60)], trackingSince: start, now: now)
    #expect(picks.chosen(from: idleAfter).isEmpty)
}

@Test func companySecurityAppsAreNeverOfferedForQuitting() {
    let mdm = app(40, "Kandji", windows: 0, bundle: "io.kandji.KandjiAgent")
    let vpn = app(41, "Client", windows: 0, bundle: "com.zscaler.Zscaler")
    let byName = app(42, "Cisco Secure Client", windows: 0, bundle: "com.example.unknown")
    let chat = app(43, "chat", windows: 0)
    #expect(!mdm.isQuittable && !vpn.isQuittable && !byName.isQuittable)
    #expect(IdleApps.candidates([mdm, vpn, byName, chat], lastActive: [:], trackingSince: start, now: now).map(\.app.id) == [43])
}

@Test func anActivationFromBeforeTheLaunchBelongsToAnEarlierProcess() {
    // pid 50 was last in front five hours ago under another app; the app now holding it launched 40 minutes ago.
    let reused = AppMemory(id: 50, name: "fresh", icon: nil, footprint: 1, bundleID: "com.example.fresh",
                           launched: now.addingTimeInterval(-40 * 60), windows: 1)
    let found = IdleApps.candidates([reused], lastActive: [50: now.addingTimeInterval(-5 * 3600)], trackingSince: start, now: now)
    #expect(found.first.map { Int($0.idle / 60) } == 40)
}

@Test func usingATickedAppTakesTheTickAwayForGood() {
    let editor = app(60, "editor", windows: 1)
    var picks = AppPicks()
    picks.set(editor, true, at: now.addingTimeInterval(-3 * 3600))
    // Brought to the front after the tick, then left alone long enough to count as unused again.
    let idle = IdleApps.candidates([editor], lastActive: [60: now.addingTimeInterval(-2 * 3600)], trackingSince: start, now: now)
    #expect(idle.map(\.id) == [60])
    #expect(!picks.isTicked(idle[0]))
    #expect(picks.chosen(from: idle).isEmpty)
}

@Test func aRecordThatCannotBeTiedToThisLaunchKeepsTheAppOut() {
    // No launch date, so a five-hour-old record may be an earlier process's under the same pid.
    let unknown = AppMemory(id: 70, name: "mystery", icon: nil, footprint: 1, bundleID: "com.example.mystery", launched: nil, windows: 1)
    #expect(IdleApps.candidates([unknown], lastActive: [70: now.addingTimeInterval(-5 * 3600)], trackingSince: start, now: now).isEmpty)
}
