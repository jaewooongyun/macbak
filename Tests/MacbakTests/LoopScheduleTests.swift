import Foundation
import Testing
@testable import Macbak

private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
    return calendar
}()

private func at(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
}

@Test func runsOnceAfterTheScheduledTime() {
    let schedule = LoopSchedule(hour: 8, minute: 30)
    let since = at(10, 1, 0, 0)
    #expect(!schedule.isDue(now: at(11, 2, 8, 29), lastRun: at(11, 1, 8, 30), enabledSince: since, calendar: calendar))
    #expect(schedule.isDue(now: at(11, 2, 8, 30), lastRun: at(11, 1, 8, 30), enabledSince: since, calendar: calendar))
    #expect(!schedule.isDue(now: at(11, 2, 9, 0), lastRun: at(11, 2, 8, 30), enabledSince: since, calendar: calendar))
}

@Test func missedRunsCatchUpOnce() {
    // Asleep from Friday 10-30 until Monday 11-02 noon: one run on wake, not three.
    let schedule = LoopSchedule(hour: 8, minute: 30)
    let woke = at(11, 2, 12, 0)
    let since = at(10, 1, 0, 0)
    #expect(schedule.isDue(now: woke, lastRun: at(10, 30, 8, 30), enabledSince: since, calendar: calendar))
    #expect(!schedule.isDue(now: woke.addingTimeInterval(60), lastRun: woke, enabledSince: since, calendar: calendar))
}

@Test func noRunForTimesBeforeTheLoopWasTurnedOn() {
    let schedule = LoopSchedule(hour: 8, minute: 30)
    #expect(!schedule.isDue(now: at(11, 2, 9, 0), lastRun: nil, enabledSince: at(11, 2, 8, 45), calendar: calendar))
}

@Test func weekdaysOnlySkipsTheWeekend() {
    // 11-06 is a Friday, 11-09 the following Monday.
    let schedule = LoopSchedule(hour: 8, minute: 30, weekdaysOnly: true)
    #expect(schedule.occurrence(after: at(11, 6, 9, 0), calendar: calendar) == at(11, 9, 8, 30))
}

@Test func historySavedBeforeRealScansStillDecodes() throws {
    let legacy = """
    [{"id":"5C6A6B4E-2F0B-4F7E-9B53-1C2D3E4F5A6B","date":800000000,"trigger":"manual","readyCount":4,"readyBytes":32000000000}]
    """
    let runs = try JSONDecoder().decode([LoopRun].self, from: Data(legacy.utf8))
    #expect(runs.count == 1)
    #expect(runs[0].source == nil)
    #expect(runs[0].readySummary == "샘플(이전 기록)")
}

@MainActor private final class ScanProbe {
    var calls = 0
    var hold = false
    /// Every scan held, so none is left waiting even if a regression starts two.
    var waiting: [CheckedContinuation<Void, Never>] = []

    func scan() async -> (count: Int, bytes: Int64)? {
        calls += 1
        if hold { await withCheckedContinuation { waiting.append($0) } }
        return (1, 1)
    }

    func release() {
        hold = false
        waiting.forEach { $0.resume() }
        waiting = []
    }
}

/// Waits until `until` holds, for up to two seconds of wall time — not a count of yields, which a busy machine can use up.
@MainActor private func settle(_ until: () -> Bool) async {
    for _ in 0..<400 where !until() { try? await Task.sleep(for: .milliseconds(5)) }
}

@MainActor @Test func aCheckIsNotStartedAgainWhileOneScans() async {
    let probe = ScanProbe()
    probe.hold = true
    let loop = LoopScheduler(system: SystemMonitor(), defaults: nil, scan: { await probe.scan() })
    loop.run(.manual)
    await settle { !probe.waiting.isEmpty }
    #expect(probe.waiting.count == 1)
    loop.run(.manual)
    // Time for a second check to reach the scan, were it started.
    try? await Task.sleep(for: .milliseconds(100))
    #expect(probe.calls == 1 && loop.isChecking)
    // Released on every path, failed expectations included.
    probe.release()
    await settle { !loop.isChecking }
    #expect(loop.history.count == 1 && !loop.isChecking)
}

@MainActor @Test func clearingHistoryDoesNotMakeTheLastCheckDueAgain() async throws {
    let probe = ScanProbe()
    let loop = LoopScheduler(system: SystemMonitor(), defaults: nil, scan: { await probe.scan() })
    loop.enabled = true
    let slot = try #require(loop.schedule.occurrence(after: .now))
    loop.runIfDue(now: slot.addingTimeInterval(1))
    await settle { !loop.isChecking }
    #expect(probe.calls == 1)
    loop.clearHistory()
    loop.runIfDue(now: slot.addingTimeInterval(2))
    await settle { !loop.isChecking }
    #expect(probe.calls == 1)
}

/// A loop that cleans records what the shallow clean-up deleted, and says so; records from before it cleaned keep saying
/// they only counted.
@MainActor @Test func aCleaningLoopRecordsWhatItDeleted() async {
    let loop = LoopScheduler(system: SystemMonitor(), defaults: nil, cleans: true, scan: { (2, 92_000_000) })
    loop.run(.manual)
    await settle { !loop.isChecking }
    let run = loop.history.first
    #expect(run?.source == .cleaned)
    #expect(run?.readySummary == "얕은 정리 2개")
    #expect(run?.hasAmount == true && run?.readyBytes == 92_000_000)

    let counting = LoopScheduler(system: SystemMonitor(), defaults: nil, scan: { (3, 1) })
    counting.run(.manual)
    await settle { !counting.isChecking }
    #expect(counting.history.first?.readySummary == "지워도 되는 것 3개 (기록만)")
}
