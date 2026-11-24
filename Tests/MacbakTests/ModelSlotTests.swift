import Foundation
import Testing
@testable import Macbak

/// A one-shot gate a job waits at, opened by the test.
private actor Gate {
    private var open = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if open { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func openUp() {
        open = true
        waiting.forEach { $0.resume() }
        waiting = []
    }
}

/// What the jobs did, in order.
private actor Log {
    private(set) var events: [String] = []
    private var running = 0
    private(set) var mostAtOnce = 0

    func add(_ event: String) { events.append(event) }
    func start() {
        running += 1
        mostAtOnce = max(mostAtOnce, running)
    }
    func end() { running -= 1 }
}

/// Waits, at most five seconds, until `condition` holds; a broken slot then fails the test instead of hanging it.
private func eventually(_ what: String, _ condition: () async -> Bool) async {
    let until = ContinuousClock.now + .seconds(5)
    while await !condition() {
        guard ContinuousClock.now < until else {
            Issue.record("never happened: \(what)")
            return
        }
        await Task.yield()
    }
}

/// Waits until `slot` has `count` callers queued, so a test knows a caller is waiting before it moves on.
private func untilWaiting(_ slot: ModelSlot, _ count: Int) async {
    await eventually("\(count) waiting") { await slot.waiting >= count }
}

/// Waits until the log holds `event`, so a test knows a job has started and holds the turn.
private func until(_ log: Log, has event: String) async {
    await eventually(event) { await log.events.contains(event) }
}

@Suite(.timeLimit(.minutes(1))) struct ModelSlotTests {
    @Test func onlyOneJobRunsAtATime() async {
        let slot = ModelSlot()
        let log = Log()
        await withTaskGroup(of: Int?.self) { group in
            for index in 0..<6 {
                group.addTask {
                    await slot.run(index.isMultiple(of: 2) ? .high : .low, deadline: .seconds(10)) {
                        await log.start()
                        try? await Task.sleep(for: .milliseconds(15))
                        await log.end()
                        return index
                    }
                }
            }
            var results: [Int] = []
            for await result in group { if let result { results.append(result) } }
            #expect(results.sorted() == Array(0..<6))
        }
        #expect(await log.mostAtOnce == 1)
    }

    @Test func aHighPriorityJobGoesBeforeAnEarlierLowOne() async {
        let slot = ModelSlot()
        let log = Log()
        let gate = Gate()
        let first = Task { await slot.run(.low, deadline: .seconds(10)) { await log.add("first in"); await gate.wait(); await log.add("first") } }
        await until(log, has: "first in")
        let low = Task { await slot.run(.low, deadline: .seconds(10)) { await log.add("low") } }
        await untilWaiting(slot, 1)
        let high = Task { await slot.run(.high, deadline: .seconds(10)) { await log.add("high") } }
        await untilWaiting(slot, 2)
        await gate.openUp()
        _ = await (first.value, low.value, high.value)
        #expect(await log.events == ["first in", "first", "high", "low"])
    }

    /// The deadline cancels a job that never looks at cancellation; the caller gets nil, and the next job starts only
    /// once that job has really returned.
    @Test func aJobPastItsDeadlineGivesNilAndFreesTheSlotOnlyWhenItEnds() async {
        let slot = ModelSlot()
        let log = Log()
        let clock = ContinuousClock()
        let started = clock.now
        let stubborn = Task {
            await slot.run(.low, deadline: .milliseconds(30)) { () -> Int in
                await log.add("stubborn started")
                let until = clock.now + .milliseconds(300)
                while clock.now < until { await Task.yield() }
                await log.add("stubborn ended")
                return 1
            }
        }
        await until(log, has: "stubborn started")
        let next = Task { await slot.run(.high, deadline: .seconds(10)) { await log.add("next started"); return 2 } }
        #expect(await stubborn.value == nil)
        #expect(await next.value == 2)
        #expect(await log.events == ["stubborn started", "stubborn ended", "next started"])
        #expect(clock.now - started >= .milliseconds(300))
    }

    @Test func aCancelledWaiterNeverRuns() async {
        let slot = ModelSlot()
        let log = Log()
        let gate = Gate()
        let holder = Task { await slot.run(.low, deadline: .seconds(10)) { await log.add("holder in"); await gate.wait(); await log.add("holder") } }
        await until(log, has: "holder in")
        let waiter = Task { await slot.run(.high, deadline: .seconds(10)) { await log.add("waiter ran") } }
        await untilWaiting(slot, 1)
        waiter.cancel()
        #expect(await waiter.value == nil)
        await gate.openUp()
        _ = await holder.value
        #expect(await log.events == ["holder in", "holder"])
        #expect(await slot.waiting == 0)
        // The turn came back: a later job runs.
        #expect(await slot.run(.low, deadline: .seconds(10)) { 7 } == 7)
    }

    /// A caller cancelled while its job ignores cancellation gets nil, and the next job starts only once that job ends.
    @Test func cancellingARunningCallerWaitsForAStubbornJob() async {
        let slot = ModelSlot()
        let log = Log()
        let clock = ContinuousClock()
        let caller = Task {
            await slot.run(.low, deadline: .seconds(30)) { () -> Int in
                await log.add("stubborn started")
                let until = clock.now + .milliseconds(200)
                while clock.now < until { await Task.yield() }
                await log.add("stubborn ended")
                return 1
            }
        }
        await until(log, has: "stubborn started")
        let next = Task { await slot.run(.high, deadline: .seconds(10)) { await log.add("next started"); return 2 } }
        await untilWaiting(slot, 1)
        caller.cancel()
        #expect(await caller.value == nil)
        #expect(await next.value == 2)
        #expect(await log.events == ["stubborn started", "stubborn ended", "next started"])
    }

    @Test func cancellingARunningCallerCancelsItsJob() async {
        let slot = ModelSlot()
        let log = Log()
        let caller = Task {
            await slot.run(.low, deadline: .seconds(30)) { () -> Int in
                await log.add("job started")
                do { try await Task.sleep(for: .seconds(20)) } catch { await log.add("job cancelled") }
                return 1
            }
        }
        await until(log, has: "job started")
        caller.cancel()
        #expect(await caller.value == nil)
        #expect(await log.events == ["job started", "job cancelled"])
        #expect(await slot.run(.high, deadline: .seconds(10)) { 3 } == 3)
    }
}
