import Foundation
import Testing
@testable import Macbak

/// The two-step judgement of a build cache found outside the usual places against the one judgement it replaced
/// (`reprove: true` throughout), on real folders: every refusal, and whether a person may pick the row, stays the same;
/// only a clean cache changes, from re-proven to ticked.
@Suite struct ProjectRowsReplacementTests {
    static func judged(_ folder: URL, context: ScanContext, lending: XcodeCacheScanner.Lending = .init()) throws -> (old: String?, new: CleanupCandidate) {
        let inputs = TargetGrant.Inputs(now: context.now, ages: context.ages, open: context.openFiles,
                                        borrowers: Array(lending.outside(folder, row: [folder])), reprove: true)
        let old = TargetGrant.evaluate(TargetGrant(kind: .derivedData, path: folder), inputs).refusal
        let new = try #require(ProjectOutputScanner.rows([folder], context: context, lending: lending, reprove: true).first)
        return (old, new)
    }

    @Test func everyRefusalStaysAndOnlyACleanCacheIsTicked() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let plain = ProjectDiscoveryTests.context(box.root)

        try box.file("dev/a/DerivedData/x/Build/blob", bytes: 2_000_000, modified: daysAgo(2))
        let noRecord = box.root.appending(path: "dev/a/DerivedData/x")
        let notShaped = try ProjectDiscoveryTests.derivedData(box, "dev/b/DerivedData/x")
        try FileManager.default.moveItem(at: notShaped.appending(path: "Build"), to: notShaped.appending(path: "Other"))
        let recent = try ProjectDiscoveryTests.derivedData(box, "dev/c/DerivedData/x", age: 0)
        let open = try ProjectDiscoveryTests.derivedData(box, "dev/d/DerivedData/x")
        let lent = try ProjectDiscoveryTests.derivedData(box, "dev/e/DerivedData/x")
        let unread = try ProjectDiscoveryTests.derivedData(box, "dev/f/DerivedData/x")
        let locked = try box.folder("dev/f/DerivedData/x/Build/locked")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let alarmed = try ProjectDiscoveryTests.derivedData(box, "dev/g/DerivedData/x", age: 0)
        try box.file("dev/g/DerivedData/x/Build/vault.kdbx", modified: daysAgo(0))
        let clean = try ProjectDiscoveryTests.derivedData(box, "dev/h/DerivedData/x")

        let cases: [(URL, ScanContext, XcodeCacheScanner.Lending, String)] = [
            (noRecord, plain, .init(), "작업 공간 기록을 읽지 못했습니다"),
            (notShaped, plain, .init(), "Xcode 빌드 캐시 모양이 아닙니다"),
            (recent, plain, .init(), "최근에 썼습니다."),
            (open, ProjectDiscoveryTests.context(box.root, open: [open.appending(path: "Build/blob").path]), .init(), "지금 쓰는 파일이 있습니다"),
            (lent, plain, .init(borrowers: [lent.path: ["/x/.git/objects/info/alternates"]]), "다른 캐시가 이 캐시의 패키지 기록을 빌려 씁니다"),
            (unread, plain, .init(), "다 훑지 못해 마지막 사용 시각을 모릅니다"),
            (alarmed, plain, .init(), CacheRules.alarmReason("vault.kdbx")),
        ]
        for (folder, context, lending, reason) in cases {
            let (old, new) = try Self.judged(folder, context: context, lending: lending)
            #expect(old == reason, "\(reason)")
            #expect(new.evidence.protectedReason == old && !new.isSelectable, "\(reason)")
        }

        let (old, new) = try Self.judged(clean, context: plain)
        #expect(old == nil && new.evidence.protectedReason == nil)
        #expect(new.isSelectable && new.isPreselected && !new.reproved && !new.manualOnly)
    }
}
