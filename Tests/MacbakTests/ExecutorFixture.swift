import Foundation
@testable import Macbak

/// An executor that may delete only inside `roots`, with nothing open, no simulators, apps or AI tools running.
/// Suites change the dependencies they test through `change`.
func fixtureExecutor(roots: [URL], audit: URL, open: [String] = [],
                     change: (inout CleanupExecutor.Dependencies) -> Void = { _ in }) -> CleanupExecutor {
    let snapshot = OpenFiles.parse(lsofOutput(open))
    var dependencies = CleanupExecutor.Dependencies(
        allowedRoots: { roots }, forbidden: [], openFiles: { snapshot }, mounts: { [] },
        simulators: { [] }, deleteSimulator: { _ in true },
        freeSpace: { 100 }, runningBundleIDs: { [] }, runningTools: { [] }, audit: CleanupAudit(url: audit), retryDelay: .zero)
    change(&dependencies)
    return CleanupExecutor(dependencies: dependencies)
}

/// A ready row a scan made just now, which the rules would tick and vouch for.
func readyRow(_ id: String, _ targets: [CleanupTarget], trusted: Bool = true) -> CleanupCandidate {
    var row = CleanupCandidate(id: id, name: id, detail: "", symbol: "doc", bytes: 1,
                               evidence: Evidence(verified: true, inUse: false, regenerable: true), targets: targets, scannedAt: .now)
    row.trusted = trusted
    return row
}
