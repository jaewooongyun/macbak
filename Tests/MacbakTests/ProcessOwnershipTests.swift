import Darwin
import Foundation
import Testing
@testable import Macbak

/// An app's memory with the helpers it is responsible for (renderers, extensions, language servers), read only while the
/// memory screen is shown; and the clean-up estimate counting each process once.
@Suite struct ProcessOwnershipTests {
    static func entry(_ pid: pid_t, footprint: UInt64?) -> ProcessSnapshot.Entry {
        ProcessSnapshot.Entry(pid: pid, ppid: 1, pgid: pid, uid: getuid(), path: "/Applications/App.app/Contents/MacOS/App", start: .now, footprint: footprint, cpu: 0)
    }

    /// Editor (pid 10, 100 B) owns 11 and 12; Browser (pid 20, 300 B) owns nothing; 30 belongs to no app.
    static func table(helper12: UInt64? = 500, unreadable: Set<pid_t> = [], truncated: Bool = false) -> ProcessSnapshot {
        let entries = [entry(10, footprint: 100), entry(11, footprint: 200), entry(12, footprint: helper12), entry(20, footprint: 300), entry(30, footprint: 900)]
        return ProcessSnapshot(entries: Dictionary(uniqueKeysWithValues: entries.map { ($0.pid, $0) }), unreadable: unreadable, truncated: truncated, taken: .now)
    }

    static let responsible: ProcessOwnership.Responsible = { pid in [10: 10, 11: 10, 12: 10, 20: 20, 30: 30][pid] }

    static let apps = [AppMemory(id: 20, name: "Browser", icon: nil, footprint: 300, windows: 2),
                       AppMemory(id: 10, name: "Editor", icon: nil, footprint: 100, windows: nil)]

    static func applied(_ table: ProcessSnapshot?, responsible: ProcessOwnership.Responsible? = Self.responsible) -> (apps: [AppMemory], state: ProcessOwnership.State) {
        let owners = table.flatMap { table in responsible.map { ProcessOwnership.owners(table, responsible: $0) } }
        return ProcessOwnership.apply(Self.apps, snapshot: table, owners: owners)
    }

    @Test func anAppsTotalIsItsOwnMemoryPlusItsHelpersAndTheListSortsByIt() {
        let (apps, state) = Self.applied(Self.table())
        #expect(apps.map(\.name) == ["Editor", "Browser"])
        let editor = apps[0]
        #expect(editor.helperPIDs == [11, 12] && editor.members == [10, 11, 12])
        #expect(editor.helpers == 700 && editor.total == 800 && editor.footprint == 100)
        #expect(apps[1].helperPIDs.isEmpty && apps[1].total == 300)
        #expect(state == .measured(unread: 0) && state.note == "보조 프로세스 포함")
        // The window count is carried through untouched, nil included.
        #expect(apps[1].windows == 2 && editor.windows == nil)
    }

    @Test func ownersAreAppPidsToTheirGroupsAndCountWhatCouldNotBePlaced() {
        let owners = ProcessOwnership.owners(Self.table(), responsible: { $0 == 30 ? nil : Self.responsible($0) })
        #expect(owners.unplaced == 1)
        #expect(ProcessOwnership.members(owners, apps: [10, 20]) == [10: [10, 11, 12], 20: [20]])
    }

    @Test func withoutTheFunctionOrAWholeListOnlyTheAppItselfIsCounted() {
        for (table, responsible, reason) in [(Self.table(), nil, "묶지 못해"), (Self.table(truncated: true), Self.responsible, "다 읽지 못해"),
                                              (nil, Self.responsible, "다 읽지 못해")] as [(ProcessSnapshot?, ProcessOwnership.Responsible?, String)] {
            let (apps, state) = Self.applied(table, responsible: responsible)
            #expect(apps.map(\.name) == ["Browser", "Editor"] && apps.allSatisfy { $0.helpers == 0 && $0.helperPIDs.isEmpty })
            guard case .unknown(let text) = state else { Issue.record("\(state)"); continue }
            #expect(text.contains(reason) && text.contains("앱 본체만"))
        }
    }

    @Test func aHelperWhoseMemoryCannotBeReadIsMarkedAsPartial() {
        let (apps, state) = Self.applied(Self.table(helper12: nil))
        #expect(apps.first { $0.id == 10 }?.total == 300)
        #expect(state == .measured(unread: 1) && state.note == "보조 프로세스 포함 · 일부 확인 못 함")
    }

    @Test func anAppWhoseOwnMemoryCannotBeReadStaysAsADash() {
        var unreadable = AppMemory(id: 10, name: "Preview", icon: nil, footprint: 0)
        unreadable.helpers = 700
        #expect(unreadable.totalText == "–")
        let (apps, _) = ProcessOwnership.apply([AppMemory(id: 10, name: "Preview", icon: nil, footprint: 0)], snapshot: Self.table(),
                                               owners: ProcessOwnership.owners(Self.table(), responsible: Self.responsible))
        #expect(apps.count == 1 && apps[0].totalText == "–")
    }

    @Test func aTableIsCompleteOnlyWhenEveryProcessWasReadAndNoneLeftOut() {
        #expect(Self.table().complete)
        #expect(!Self.table(unreadable: [40, 41]).complete)
        #expect(!Self.table(truncated: true).complete)
    }

    @Test func theEstimateCountsAProcessHeldByTwoChoicesOnce() {
        // A session and the terminal it runs in both hold pid 11.
        #expect(ProcessOwnership.union([[10, 11, 12], [11, 30]], in: Self.table()) == 100 + 200 + 500 + 900)
        #expect(ProcessOwnership.union([[10, 11], [11]], in: Self.table()) == 300)
    }

    @Test func theRunStepAndTheIdleRowCarryTheTotal() {
        let (apps, _) = Self.applied(Self.table())
        let editor = apps[0]
        #expect(editor.runStep.amount == 800 && editor.runStep.amountText == editor.totalText)
        let idle = IdleApps.candidates([editor], lastActive: [:], trackingSince: .now.addingTimeInterval(-7200), now: .now)
        #expect(idle.map(\.app.total) == [800])
    }

    // MARK: This Mac

    @Test func thisMacHasTheFunctionAndATableWithThisProcessAndLaunchd() throws {
        let responsible = try #require(ProcessOwnership.live)
        let me = getpid()
        #expect(responsible(me) != nil)
        let table = try #require(ProcessSnapshot.capture())
        let mine = try #require(table.entries[me])
        #expect(mine.uid == getuid() && mine.start != nil && mine.path != nil && (mine.footprint ?? 0) > 0 && mine.cpu != nil)
        // The kernel's name is the executable's file name, cut at 32 characters; never an argument.
        #expect(mine.name == mine.path.map { String(($0 as NSString).lastPathComponent.prefix(32)) })
        // launchd belongs to root: only its parent, group and owner can be read, and it is still listed.
        let launchd = try #require(table.entries[1])
        #expect(launchd.uid == 0 && launchd.start == nil && launchd.footprint == nil)
    }

    // MARK: Only while the memory screen is shown

    final class Walks: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func add() { lock.withLock { count += 1 } }
        var total: Int { lock.withLock { count } }
    }

    @MainActor @Test func nothingIsWalkedWhileTheMemoryScreenIsNotShown() async throws {
        let walks = Walks()
        let services = Walks()
        let sessions = Walks()
        // One orphaned tool too, at a pid past macOS's limit so no running app can hold it.
        var table = Self.table()
        table.entries[999_999] = ProcessSnapshot.Entry(pid: 999_999, ppid: 1, pgid: 999_998, uid: getuid(), path: NSHomeDirectory() + "/.nvm/versions/node/v1/bin/node",
                                                       start: .now.addingTimeInterval(-3600), footprint: 1, cpu: 0)
        // And a Claude session idle for two days; its activity needs two readings, ten seconds apart here.
        let started = Date(timeIntervalSince1970: Date.now.addingTimeInterval(-3600).timeIntervalSince1970.rounded(.down))
        table.entries[999_990] = ProcessSnapshot.Entry(pid: 999_990, ppid: 1, pgid: 999_990, uid: getuid(), name: "claude.exe", start: started, footprint: 5, cpu: 0)
        let idle = AISessions.Record(pid: 999_990, procStart: started, status: "idle", updatedAt: .now.addingTimeInterval(-48 * 3600), kind: "interactive", jobId: nil, name: "s")
        let sources = SystemMonitor.ProcessSources(snapshot: { [table] in
            walks.add()
            return ProcessSnapshot(entries: table.entries, taken: .now.addingTimeInterval(Double(walks.total) * 10))
        }, responsible: Self.responsible, services: { services.add(); return [] }, sessions: { sessions.add(); return [idle] }, jobStates: { _ in [:] })
        let monitor = SystemMonitor(processes: sources)
        monitor.refreshAll()
        await monitor.refreshProcesses()
        try await Task.sleep(for: .milliseconds(200))
        #expect(walks.total == 0 && services.total == 0 && sessions.total == 0 && monitor.ownership == .off && monitor.processes == nil)

        monitor.memoryScreenShown = true
        await monitor.refreshProcesses()
        #expect(walks.total == 1 && services.total == 1 && sessions.total == 1 && monitor.ownership == .measured(unread: 0) && monitor.processes != nil)
        #expect(monitor.orphans.map(\.pid) == [999_999])
        // The ten-second refresh reads them too while the screen is shown.
        monitor.refreshAll()
        for _ in 0..<50 where walks.total < 2 || monitor.idleSessions.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(walks.total == 2 && monitor.idleSessions.map(\.id) == [999_990])

        monitor.memoryScreenShown = false
        monitor.refreshAll()
        await monitor.refreshProcesses()
        #expect(walks.total == 2 && services.total == 2 && sessions.total == 2 && monitor.ownership == .off && monitor.processes == nil && monitor.orphans.isEmpty)
        #expect(monitor.idleSessions.isEmpty)
    }

    /// Set once from the read's thread, seen from the test.
    final class Started: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func mark() { lock.withLock { value = true } }
        var isMarked: Bool { lock.withLock { value } }
    }

    @MainActor @Test func aReadThatEndsAfterTheScreenClosedIsDropped() async {
        // The read is held until the screen has closed, whatever the machine's load.
        let started = Started(), release = DispatchSemaphore(value: 0)
        let sources = SystemMonitor.ProcessSources(snapshot: { started.mark(); release.wait(); return Self.table() }, responsible: Self.responsible)
        let monitor = SystemMonitor(processes: sources)
        monitor.memoryScreenShown = true
        let reading = Task { await monitor.refreshProcesses() }
        while !started.isMarked { try? await Task.sleep(for: .milliseconds(5)) }
        monitor.memoryScreenShown = false
        release.signal()
        await reading.value
        #expect(monitor.ownership == .off && monitor.processes == nil)
    }
}
