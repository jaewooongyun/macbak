import Foundation
import Testing
@testable import Macbak

/// What the on-device model may change on a row: an offer makes it a choice (never ticked), a "user data" answer keeps
/// it protected with that reason, and a row changed within three days stays protected whatever the model says.
@MainActor
@Test func explorerFindingsOnlyEverMakeAChoice() {
    func pending(_ id: String, recent: Bool = false) -> CleanupCandidate {
        var evidence = Evidence(verified: true, inUse: false, regenerable: true)
        evidence.recentlyUsed = recent
        evidence.protectedReason = "기기 AI가 확인하기 전까지 지우지 않습니다."
        var row = CleanupCandidate(id: id, name: id, detail: "", symbol: "folder", bytes: 2_000_000, evidence: evidence,
                                   targets: [CleanupTarget(path: URL(fileURLWithPath: "/tmp/x/a"), root: URL(fileURLWithPath: "/tmp/x"), identity: nil, action: .removeItem)])
        row.exploreInput = ExploreInput(url: URL(fileURLWithPath: "/tmp/x"), relative: ".cache/\(id)", inside: "a", beside: "")
        return row
    }
    let coordinator = CleanupCoordinator(fixture: [.general: [pending("offered"), pending("user"), pending("recent", recent: true)]])
    #expect(coordinator.all.allSatisfy { $0.verdict.status == .protected })

    coordinator.apply(CacheExplorer.Finding(offered: true, decision: "regenerable", evidence: "hash-like blobs"), to: "offered")
    coordinator.apply(CacheExplorer.Finding(offered: false, decision: "userData", evidence: "notes.txt"), to: "user")
    coordinator.apply(CacheExplorer.Finding(offered: true, decision: "regenerable", evidence: "blobs"), to: "recent")
    let rows = Dictionary(uniqueKeysWithValues: coordinator.all.map { ($0.id, $0) })

    #expect(rows["offered"]?.verdict.status == .review)
    #expect(rows["offered"]?.isPreselected == false)
    #expect(rows["offered"]?.aiEvidence == "hash-like blobs")
    #expect(rows["user"]?.verdict.status == .protected)
    #expect(rows["user"]?.verdict.reason == "기기 AI가 사용자 데이터로 봤습니다.")
    #expect(rows["recent"]?.verdict.status == .protected)
}

/// The model's probes read names, sizes and dates only, and never reach outside the item.
@Test func explorerProbesStayInsideTheItem() throws {
    let box = try Sandbox()
    defer { box.remove() }
    try box.file(".cache/tool/a1b2c3d4e5/blob", bytes: 4096, modified: daysAgo(5))
    try box.file(".cache/tool/index.json", bytes: 100, modified: daysAgo(5))
    try box.file(".cache/other/secret.txt", bytes: 100, modified: daysAgo(5))
    let item = box.root.appending(path: ".cache/tool")
    let measured = ExplorerProbes.measure(item)
    #expect(measured.hasPrefix("2 files"))
    let deeper = ExplorerProbes.listDeeper(item)
    #expect(deeper.contains("a1b2c3d4e5/") && !deeper.contains("secret"))
}

/// The separate checklist session has the last word: an explorer's "regenerable" is offered only when the checklist
/// also calls the item rebuildable and raises no warning.
@Test func bothModelSessionsMustAgreeBeforeAnOffer() {
    typealias Finding = CacheExplorer.Finding
    #expect(Finding.offers(decision: "regenerable", holdsUserContent: false, isMachineOrImage: false, isSettingsOrState: false, isRebuildable: true))
    #expect(!Finding.offers(decision: "regenerable", holdsUserContent: false, isMachineOrImage: false, isSettingsOrState: false, isRebuildable: false))
    #expect(!Finding.offers(decision: "regenerable", holdsUserContent: true, isMachineOrImage: false, isSettingsOrState: false, isRebuildable: true))
    #expect(!Finding.offers(decision: "regenerable", holdsUserContent: false, isMachineOrImage: true, isSettingsOrState: false, isRebuildable: true))
    #expect(!Finding.offers(decision: "regenerable", holdsUserContent: false, isMachineOrImage: false, isSettingsOrState: true, isRebuildable: true))
    #expect(!Finding.offers(decision: "unknown", holdsUserContent: false, isMachineOrImage: false, isSettingsOrState: false, isRebuildable: true))
}
