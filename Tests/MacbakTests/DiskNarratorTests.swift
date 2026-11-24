import Foundation
import Testing
@testable import Macbak

/// Counts the times the model was asked.
private actor Asked {
    private(set) var count = 0
    func add() { count += 1 }
}

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

/// Waits, at most five seconds, until `condition` holds.
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

/// The disk summary: the code measures and writes, the on-device model only picks among true headlines and the facts.
@Suite(.timeLimit(.minutes(1))) struct DiskNarratorTests {
    static let gb: Int64 = 1_000_000_000

    static func row(_ id: String, _ gb: Double, _ evidence: Evidence, targets: Bool = true, command: String? = nil) -> CleanupCandidate {
        let target = CleanupTarget(path: URL(fileURLWithPath: "/tmp/\(id)"), root: URL(fileURLWithPath: "/tmp"), identity: nil, action: .removeItem)
        var row = CleanupCandidate(id: id, name: id, detail: "", symbol: "folder", bytes: Int64(gb * 1e9), evidence: evidence,
                                   targets: targets ? [target] : [], scannedAt: .now)
        row.toolCommand = command
        return row
    }

    static let ready = Evidence(verified: true, inUse: false, regenerable: true)

    static var choice: Evidence {
        var evidence = ready
        evidence.downloadCost = true
        return evidence
    }

    static func kept(_ reason: String) -> Evidence {
        var evidence = Evidence()
        evidence.protectedReason = reason
        return evidence
    }

    /// Two ready rows (4 GB), one ready row with nothing to delete, one choice (2 GB), five kept rows (10, 6, 4, 3 and
    /// 0.5 GB) and two unsure ones (1 and 7 GB; the larger would be named among the kept if unsure rows counted there).
    static func rows(firstReady: Double = 3) -> [CleanupCandidate] {
        [
            row("ra", firstReady, ready), row("rb", 1, ready), row("info", 5, ready, targets: false),
            row("ca", 2, choice),
            row("ka", 10, kept("보호 A"), command: "docker system prune"), row("kb", 6, kept("보호 B")), row("kc", 4, kept("보호 C")),
            row("kd", 3, kept("보호 D")), row("ke", 0.5, kept("보호 E")),
            row("ua", 1, kept(CacheRules.unsureReason)), row("ub", 7, kept(CacheRules.modelUnsureReason)),
        ]
    }

    static func disk(total: Int64, available: Int64) -> DiskUsage {
        DiskUsage(name: "Macintosh HD", total: total * gb, available: available * gb, availableNow: available * gb)
    }

    /// 5% free of 1000 GB, an Android Mac, a project scan that ran out of time.
    static func tight(firstReady: Double = 3) -> DiskNarrator.Brief {
        var found = ProjectDiscovery.Result()
        found.partial = true
        return DiskNarrator.brief(rows: rows(firstReady: firstReady), disk: disk(total: 1000, available: 50),
                                  environment: WorkEnvironment(kinds: [.android]), discovery: found)
    }

    /// Half of 100 GB free; nothing found about the Mac's work.
    static let roomy = DiskNarrator.brief(rows: rows(), disk: disk(total: 100, available: 50), environment: nil, discovery: nil)

    static func text(_ brief: DiskNarrator.Brief, _ id: DiskNarrator.Fact.ID) -> String? {
        brief.facts.first { $0.id == id }?.text
    }

    @Test func factsAddUpTheRowsAndNameTheLargestKept() {
        let brief = Self.tight()
        #expect(brief.facts.map(\.id) == [.space, .ready, .choice, .kept1, .kept2, .kept3, .unsure, .environment, .partial])
        #expect(Self.text(brief, .space) == "사용 가능 공간은 전체의 5%입니다.")
        #expect(Self.text(brief, .ready) == "지워도 되는 것 2개, 4 GB", "a row with nothing to delete is not counted")
        #expect(Self.text(brief, .choice) == "골라서 지울 것 1개, 2 GB")
        #expect(Self.text(brief, .kept1) == "ka 10 GB: 보호 A (docker system prune)")
        #expect(Self.text(brief, .kept2) == "kb 6 GB: 보호 B")
        #expect(Self.text(brief, .kept3) == "kc 4 GB: 보호 C")
        #expect(Self.text(brief, .unsure) == "판단할 근거가 부족해 지키는 것 2개, 8 GB")
        #expect(Self.text(brief, .environment) == "이 Mac에서 찾은 작업: Android 개발")
        #expect(Self.text(brief, .partial) == "프로젝트 검사는 시간이 다 돼 일부만 봤습니다.")
        // 6 GB to clean is under 5% of 1000 GB and over 1 GB; 31.5 GB held is under 5% of the disk.
        #expect(brief.headlines == [.tight])
        // 6 GB is at least 5% of 100 GB, and 31.5 GB held is twice that and over 5 GB.
        #expect(Self.roomy.headlines == [.muchToClean, .mostlyKept, .roomy])
        #expect(Self.roomy.facts.map(\.id) == [.space, .ready, .choice, .kept1, .kept2, .kept3, .unsure])
        let empty = DiskNarrator.brief(rows: [], disk: Self.disk(total: 1000, available: 500), environment: WorkEnvironment(), discovery: nil)
        #expect(empty.headlines == [.nothingToDo, .roomy])
        #expect(empty.facts.map(\.id) == [.space])
        // 15 GB held is over 5% of 100 GB but not twice the 20 GB to clean; a kept row under 1 GB is not named.
        let cleanMore = DiskNarrator.brief(rows: [Self.row("ra", 20, Self.ready), Self.row("ka", 15, Self.kept("x")), Self.row("kb", 0.5, Self.kept("y"))],
                                           disk: Self.disk(total: 100, available: 50), environment: nil, discovery: nil)
        #expect(cleanMore.headlines == [.muchToClean, .roomy])
        #expect(cleanMore.facts.map(\.id) == [.space, .ready, .kept1])
        // The template: the first true headline and the heaviest facts, free space first only when it is tight.
        #expect(DiskNarrator.template(brief) == .init(headline: .tight, facts: brief.facts.filter { [.space, .kept1, .unsure].contains($0.id) }, byModel: false))
        #expect(DiskNarrator.template(Self.roomy).facts.map(\.id) == [.kept1, .unsure, .kept2])
        #expect(DiskNarrator.template(empty) == .init(headline: .nothingToDo, facts: [], byModel: false))
    }

    @Test func theModelOnlyPicksFactsAndAHeadline() {
        let brief = Self.roomy
        let template = DiskNarrator.template(brief)
        // Facts the brief does not hold are dropped, each fact shows once, and three at most.
        let picked = DiskNarrator.assembled(.init(headline: .mostlyKept, facts: [.partial, .unsure, .unsure, .ready, .kept1, .choice]), brief)
        #expect(picked.headline == .mostlyKept && picked.byModel)
        #expect(picked.facts.map(\.id) == [.unsure, .ready, .kept1])
        // A headline that is not true, no headline, or no fact left: the template.
        #expect(DiskNarrator.assembled(.init(headline: .tight, facts: [.ready]), brief) == template)
        #expect(DiskNarrator.assembled(.init(headline: nil, facts: [.ready]), brief) == template)
        #expect(DiskNarrator.assembled(.init(headline: .roomy, facts: [.partial, .environment]), brief) == template)
        #expect(DiskNarrator.assembled(.init(headline: .roomy, facts: []), brief) == template)
    }

    @MainActor @Test func noModelOrAFailureGivesTheTemplate() async {
        let brief = Self.tight()
        let narrator = DiskNarrator(slot: ModelSlot(), choose: { _ in nil })
        #expect(narrator.narration(for: brief) == DiskNarrator.template(brief), "before asking")
        await narrator.narrate(brief)
        #expect(narrator.answer == .init(key: brief.key, choice: nil))
        #expect(narrator.narration(for: brief) == DiskNarrator.template(brief))
    }

    @MainActor @Test func theSameFactsAreAskedOnce() async {
        let asked = Asked()
        let slot = ModelSlot()
        let narrator = DiskNarrator(slot: slot, choose: { brief in
            await asked.add()
            return .init(headline: brief.headlines.first, facts: [.ready])
        })
        let brief = Self.tight()
        await narrator.narrate(brief)
        await narrator.narrate(brief)
        #expect(await asked.count == 1)
        // Only a number moved: the same pick, with the number as it is now.
        let grown = Self.tight(firstReady: 7)
        #expect(grown.key == brief.key)
        await narrator.narrate(grown)
        #expect(await asked.count == 1)
        #expect(narrator.narration(for: grown).byModel)
        #expect(narrator.narration(for: grown).lines.contains("지워도 되는 것 2개, 8 GB"))
        await narrator.narrate(Self.roomy)
        #expect(await asked.count == 2)

        // A call cancelled while it waits for the slot records nothing, so the next one asks.
        let other = DiskNarrator.brief(rows: [], disk: Self.disk(total: 1000, available: 500), environment: nil, discovery: nil)
        let latch = Latch()
        let entered = Asked()
        let holder = Task { await slot.run(.high, deadline: .seconds(10)) { await entered.add(); await latch.wait() } }
        await eventually("the slot is held") { await entered.count == 1 }
        let waiting = Task { await narrator.narrate(other) }
        await eventually("the summary waits") { await slot.waiting == 1 }
        waiting.cancel()
        await waiting.value
        await latch.openUp()
        _ = await holder.value
        #expect(narrator.answer?.key == Self.roomy.key, "a cancelled call records nothing")
        await narrator.narrate(other)
        #expect(await asked.count == 3)
        #expect(narrator.answer?.key == other.key)
    }

    /// The numbers expected are worked out by hand from the rows above, not from `brief`; headlines hold none.
    @Test func everyNumberShownComesFromTheFacts() throws {
        let brief = Self.tight()
        // 5% free; 2 ready of 4 GB; 1 choice of 2 GB; kept 10, 6 and 4 GB; 2 unsure of 8 GB.
        let measured: Set<String> = ["5", "2", "4", "1", "10", "6", "8"]
        let number = try Regex("[0-9]+(?:\\.[0-9]+)?")
        for headline in DiskNarrator.Headline.allCases {
            #expect(headline.text.matches(of: number).isEmpty, "\(headline)")
        }
        var shown = [DiskNarrator.template(brief)]
        let ids = brief.facts.map(\.id)
        for headline in DiskNarrator.Headline.allCases {
            for a in ids {
                for b in ids {
                    for c in ids { shown.append(DiskNarrator.assembled(.init(headline: headline, facts: [a, b, c]), brief)) }
                }
            }
        }
        for narration in shown {
            for line in narration.lines {
                for match in line.matches(of: number) {
                    #expect(measured.contains(String(line[match.range])), "\(line)")
                }
            }
        }
    }

    @MainActor @Test func aScanNeverStartsTheNarrator() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let asked = Asked()
        var scanning = CleanupCoordinator.Scanning()
        scanning.context = { ages in ProjectDiscoveryTests.context(box.root, ages: ages) }
        scanning.area = { _, _ in [] }
        let narrator = DiskNarrator(slot: ModelSlot(), choose: { _ in await asked.add(); return nil })
        let coordinator = CleanupCoordinator(scanning: scanning, narrator: narrator)
        await coordinator.scan()
        await coordinator.scan()
        #expect(await asked.count == 0)
        #expect(narrator.answer == nil)
    }

    /// The summary waits for a scan in progress and is not asked while the explorer looks, so it never holds the model
    /// while rows wait on the explorer.
    @MainActor @Test func theSummaryWaitsForTheScanAndTheExplorer() async throws {
        let asked = Asked()
        let narrator = { DiskNarrator(slot: ModelSlot(), choose: { brief in await asked.add(); return .init(headline: brief.headlines.first, facts: [.space]) }) }
        let exploring = CleanupCoordinator(fixture: [:], explorer: CacheExplorer(fixture: .exploring(done: 0, total: 1, current: "x")), narrator: narrator())
        await exploring.summarize { Self.roomy }
        #expect(await asked.count == 0)

        let box = try Sandbox()
        defer { box.remove() }
        let latch = Latch()
        var scanning = CleanupCoordinator.Scanning()
        scanning.context = { ages in
            await latch.wait()
            return ProjectDiscoveryTests.context(box.root, ages: ages)
        }
        scanning.area = { _, _ in [] }
        let coordinator = CleanupCoordinator(scanning: scanning, narrator: narrator())
        let scan = Task { await coordinator.scan() }
        await eventually("the scan started") { !coordinator.scanning.isEmpty }
        let summary = Task { await coordinator.summarize { Self.roomy } }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await asked.count == 0, "asked during the scan")
        await latch.openUp()
        await scan.value
        await summary.value
        #expect(await asked.count == 1)
        #expect(coordinator.narrator.narration(for: Self.roomy).byModel)
    }

    #if canImport(FoundationModels)
    /// The model's words are the code's: every headline and fact id the model can give maps onto one the code knows.
    @Test func theModelsWordsMapOntoTheCodes() {
        guard #available(macOS 26.0, *) else { return }
        #expect(NarrationHeadline.allCases.map { DiskNarrator.Headline(rawValue: "\($0)") } == DiskNarrator.Headline.allCases)
        #expect(NarrationFact.allCases.map { DiskNarrator.Fact.ID(rawValue: "\($0)") } == DiskNarrator.Fact.ID.allCases)
    }
    #endif
}
