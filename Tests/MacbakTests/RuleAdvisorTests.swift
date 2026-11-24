import Foundation
import Testing
@testable import Macbak

/// A one-shot gate, opened by the test.
private actor Latch {
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

/// Whether the model can run, switched by the test.
private final class Availability: @unchecked Sendable {
    var reason: String?
    init(_ reason: String?) { self.reason = reason }
}

/// What the jobs did, in order.
private actor Events {
    private(set) var all: [String] = []
    func add(_ event: String) { all.append(event) }
}

@MainActor
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

/// Asking the on-device model about a folder nothing could tell: only a click asks, in the model's low lane, and only
/// both sessions agreeing makes a proposal a person may approve.
@Suite(.timeLimit(.minutes(1))) struct RuleAdvisorTests {
    static func input(_ name: String) -> ExploreInput {
        ExploreInput(url: URL(fileURLWithPath: "/nonexistent/\(name)"), relative: "Library/Application Support/X/\(name)", inside: "a", beside: "")
    }

    /// A folder that is not on disk, whose names are `inside`.
    static func listing(_ inside: String) -> ExploreInput {
        ExploreInput(url: URL(fileURLWithPath: "/nonexistent/listing"), relative: "Library/Application Support/X/listing", inside: inside, beside: "")
    }

    static let regenerable = CacheExplorer.Finding(offered: true, decision: "regenerable", evidence: "hash-named files")

    @Test func answersMapToProposalsOnlyWhenBothSessionsAgree() {
        func finding(_ decision: String, userContent: Bool = false, image: Bool = false, settings: Bool = false, rebuildable: Bool = true) -> CacheExplorer.Finding {
            let offered = CacheExplorer.Finding.offers(decision: decision, holdsUserContent: userContent, isMachineOrImage: image,
                                                       isSettingsOrState: settings, isRebuildable: rebuildable)
            return CacheExplorer.Finding(offered: offered, decision: decision, evidence: "e", warned: userContent || image || settings)
        }
        #expect(RuleAdvisor.answer(finding("regenerable"), input: Self.input("a")) == .proposal(evidence: "e"))
        // The checklist does not agree it is rebuildable, or warns: no proposal.
        #expect(RuleAdvisor.answer(finding("regenerable", rebuildable: false), input: Self.input("a")) == .unsure(reason: "기기 AI도 판단하지 못했습니다."))
        #expect(RuleAdvisor.answer(finding("regenerable", settings: true), input: Self.input("a")) == .kept(evidence: "e"))
        #expect(RuleAdvisor.answer(finding("regenerable", image: true), input: Self.input("a")) == .kept(evidence: "e"))
        #expect(RuleAdvisor.answer(finding("userData"), input: Self.input("a")) == .kept(evidence: "e"))
        for decision in ["unknown", "unavailable"] {
            #expect(RuleAdvisor.answer(finding(decision), input: Self.input("a")) == .unsure(reason: "기기 AI도 판단하지 못했습니다."), "\(decision)")
        }
        // A failed model call is no answer: the row may be asked again.
        #expect(RuleAdvisor.answer(finding("error"), input: Self.input("a")) == .unavailable(reason: "기기 AI가 답하지 못했습니다."))
    }

    /// A folder whose names show someone's sessions, memories, backups or settings is never proposed, whatever the model
    /// saw: the listing below is shaped like the coding assistant folder the model proposed on 2026-11-24.
    @Test func aFolderThatShowsStateIsNeverProposed() {
        let offered = CacheExplorer.Finding(offered: true, decision: "regenerable", evidence: "e")
        let assistant = "Agents/ (XcodeVersions/, claude/, codex/), AgentConfig/ (Backups/, plugins/, projects/), codex/ (cache/, Memories/), servers.json"
        #expect(CacheRules.stateName(in: assistant) == "Backups")
        guard case .unsure(let reason) = RuleAdvisor.answer(offered, input: Self.listing(assistant)) else {
            Issue.record("proposed a folder holding backups and memories")
            return
        }
        #expect(reason.contains("Backups"))
        for state in ["sessions/", "x/ (Local Storage/, a)", "mcp-servers.json", "config", "History/ (1, 2)", "sessions.jsonl", ".config/", "Settings.plist"] {
            #expect(RuleAdvisor.answer(offered, input: Self.listing("a, " + state)) != .proposal(evidence: "e"), "\(state)")
        }
        // Cache-shaped names still make a proposal; a name only containing a state word is not one.
        #expect(RuleAdvisor.answer(offered, input: Self.listing("Cache_Data/ (data_0, index), GPUCache/, sessionless.bin, configs-old")) == .proposal(evidence: "e"))
    }

    /// The rules listing stops after eight names: a `sessions/` sorted after many hash-named files is found by reading
    /// the folder itself.
    @Test func stateNamesPastTheListingStillCount() throws {
        let box = try Sandbox()
        defer { box.remove() }
        for index in 0..<9 { try box.file("Library/Application Support/X/blob/0\(index)ab", bytes: 10) }
        try box.folder("Library/Application Support/X/blob/sessions")
        let listing = CacheRules.listing(home: box.root, relative: "Library/Application Support/X/blob")
        #expect(!listing.inside.contains("sessions"), "the listing does not show it")
        let input = ExploreInput(url: box.root.appending(path: "Library/Application Support/X/blob"), relative: "Library/Application Support/X/blob",
                                 inside: listing.inside, beside: "")
        #expect(RuleAdvisor.answer(.init(offered: true, decision: "regenerable", evidence: "e"), input: input) != .proposal(evidence: "e"))
    }

    /// Without the model nothing is looked at and each row says why; once the model can run, asking again looks.
    @MainActor @Test func withoutAModelThereIsNoAskingButAReason() async {
        let events = Events()
        let availability = Availability("macOS 26 이상에서 기기 AI가 남은 항목을 함께 살펴봅니다.")
        let advisor = RuleAdvisor(slot: ModelSlot(), look: { _ in await events.add("look"); return Self.regenerable },
                                  unavailable: { availability.reason })
        advisor.ask([(id: "a", input: Self.input("a")), (id: "b", input: Self.input("b"))])
        #expect(advisor.answer(for: "a", input: Self.input("a")) == .unavailable(reason: "macOS 26 이상에서 기기 AI가 남은 항목을 함께 살펴봅니다."))
        #expect(advisor.answer(for: "b", input: Self.input("b")) == .unavailable(reason: "macOS 26 이상에서 기기 AI가 남은 항목을 함께 살펴봅니다."))
        #expect(advisor.progress == nil)
        await Task.yield()
        #expect(await events.all.isEmpty)
        #expect(advisor.mayAsk("a", input: Self.input("a")), "the row can be asked again")
        availability.reason = nil
        advisor.ask([(id: "a", input: Self.input("a"))])
        await eventually("answered") { advisor.progress == nil }
        #expect(await events.all == ["look"])
        #expect(advisor.answer(for: "a", input: Self.input("a")) == .proposal(evidence: "hash-named files"))
        #expect(!advisor.mayAsk("a", input: Self.input("a")))
    }

    /// One click asks at most a batch, never a row already asked; the coordinator hands over the largest, or the ones named.
    @MainActor @Test func oneClickAsksAtMostABatch() async {
        let events = Events()
        let advisor = RuleAdvisor(slot: ModelSlot(), look: { input in await events.add(input.relative); return Self.regenerable }, unavailable: { nil })
        let items = (0..<25).map { (id: "r\($0)", input: Self.input("r\($0)")) }
        advisor.ask(items)
        #expect(advisor.progress == .init(done: 0, total: 20))
        await eventually("the batch ends") { advisor.progress == nil }
        #expect(await events.all.count == 20)
        advisor.ask(items)
        await eventually("the rest end") { advisor.progress == nil }
        #expect(await events.all.count == 25, "only the five not asked yet")
        advisor.ask(items)
        #expect(advisor.progress == nil && advisor.answers.count == 25)

        func row(_ index: Int) -> CleanupCandidate {
            var row = CleanupCandidate(id: "a\(index)", name: "a\(index)", detail: "", symbol: "folder", bytes: Int64(index) * 1_000_000, evidence: Evidence())
            row.askInput = Self.input("a\(index)")
            return row
        }
        let instant = { RuleAdvisor(slot: ModelSlot(), look: { _ in Self.regenerable }, unavailable: { nil }) }
        let coordinator = CleanupCoordinator(fixture: [.general: (0..<25).map(row) + [CleanupCandidate(id: "plain", name: "p", detail: "", symbol: "folder", bytes: 9_000_000_000, evidence: Evidence())]],
                                             advisor: instant())
        #expect(coordinator.askable.count == 25)
        coordinator.ask()
        await eventually("the batch ends") { coordinator.advisor.progress == nil }
        #expect(coordinator.askable.map(\.id).sorted() == (0..<5).map { "a\($0)" }, "answered rows are no longer counted")
        #expect(Set(coordinator.advisor.answers.keys) == Set((5..<25).map { "a\($0)" }), "the twenty largest a person may ask about")
        let named = CleanupCoordinator(fixture: [.general: (0..<25).map(row)], advisor: instant())
        named.ask(["a3", "plain"])
        #expect(Array(named.advisor.answers.keys) == ["a3"])
    }

    @MainActor @Test func askingWaitsForTheLowLane() async {
        let slot = ModelSlot()
        let events = Events()
        let latch = Latch()
        let holder = Task { await slot.run(.high, deadline: .seconds(10)) { await events.add("holder"); await latch.wait() } }
        await eventually("the slot is held") { await events.all == ["holder"] }
        let advisor = RuleAdvisor(slot: slot, look: { _ in await events.add("advisor"); return Self.regenerable }, unavailable: { nil })
        advisor.ask([(id: "a", input: Self.input("a"))])
        #expect(advisor.answer(for: "a", input: Self.input("a")) == .asking)
        await eventually("the advisor waits") { await slot.waiting == 1 }
        let explorer = Task { await slot.run(.high, deadline: .seconds(10)) { await events.add("explorer") } }
        await eventually("the explorer waits") { await slot.waiting == 2 }
        await latch.openUp()
        _ = await (holder.value, explorer.value)
        await eventually("answered") { advisor.answer(for: "a", input: Self.input("a")) != .asking }
        #expect(await events.all == ["holder", "explorer", "advisor"])
        #expect(advisor.answer(for: "a", input: Self.input("a")) == .proposal(evidence: "hash-named files"))
        #expect(advisor.progress == nil)
    }

    /// An answer counts only while the folder shows the names the model saw: a rescan that finds them unchanged keeps it
    /// (approving one proposal does not lose the others), one that finds them changed asks again, and an answer for the
    /// old names never lands over the new asking.
    @MainActor @Test func answersFromAnOlderScanAreDropped() async {
        let before = Latch()
        let after = Latch()
        let events = Events()
        let advisor = RuleAdvisor(slot: ModelSlot(), look: { input in
            await events.add(input.inside)
            await (input.inside == "before" ? before : after).wait()
            return Self.regenerable
        }, unavailable: { nil })
        let old = ExploreInput(url: URL(fileURLWithPath: "/nonexistent/a"), relative: "Library/Application Support/X/a", inside: "before", beside: "")
        let new = ExploreInput(url: URL(fileURLWithPath: "/nonexistent/a"), relative: "Library/Application Support/X/a", inside: "after", beside: "")
        advisor.ask([(id: "a", input: old)])
        await eventually("looking at the old names") { await events.all == ["before"] }
        #expect(advisor.answer(for: "a", input: new) == nil, "the names changed")
        advisor.ask([(id: "a", input: new)])
        await before.openUp()
        await eventually("looking at the new names") { await events.all == ["before", "after"] }
        #expect(advisor.answer(for: "a", input: new) == .asking, "the old answer did not land over the new asking")
        await after.openUp()
        await eventually("answered") { advisor.progress == nil }
        #expect(advisor.answer(for: "a", input: new) == .proposal(evidence: "hash-named files"))
        #expect(advisor.answer(for: "a", input: old) == nil)
        // The same names again, as after a rescan: kept, and not looked at again.
        advisor.ask([(id: "a", input: new)])
        #expect(advisor.progress == nil)
        #expect(await events.all.count == 2)
    }
}
