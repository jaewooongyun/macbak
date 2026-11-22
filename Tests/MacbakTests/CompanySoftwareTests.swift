import Foundation
import Testing
@testable import Macbak

@Test func companySecuritySoftwareIsNeverOffered() throws {
    let box = try Sandbox()
    defer { box.remove() }
    try box.file("Library/Caches/com.zscaler.Zscaler/cache.db", bytes: 2_000_000, modified: daysAgo(10))
    try box.file("Library/Caches/io.kandji.KandjiAgent/blob", bytes: 2_000_000, modified: daysAgo(10))
    try box.file("Library/Caches/com.example.tool/blob", bytes: 2_000_000, modified: daysAgo(4))
    try box.file("Library/Caches/com.example.busy/blob", bytes: 2_000_000, modified: daysAgo(1))
    try box.file("Library/Logs/Netskope/old.log", bytes: 2_000_000, modified: daysAgo(40))
    try box.file("Library/Logs/Editor/old.log", bytes: 2_000_000, modified: daysAgo(40))
    let context = ScanContext(home: box.root, now: .now, openFiles: OpenFiles.parse(lsofOutput([])), runningBundleIDs: [], installedBundleIDs: [])

    let found = AppCacheScanner.scan(context)
    let names = Set(found.map(\.name))
    #expect(!names.contains("com.zscaler.Zscaler"))
    #expect(!names.contains("io.kandji.KandjiAgent"))
    // A cache untouched for three days goes even when its app is not identified; one used yesterday stays.
    #expect(found.first { $0.name == "com.example.tool" }?.verdict.status == .ready)
    #expect(found.first { $0.name == "com.example.busy" }?.verdict.status == .protected)
    let logs = try #require(found.first { $0.id == "logs.old" })
    let logPaths = logs.targets.flatMap { target -> [String] in
        if case .removeFiles(let files) = target.action { return files.map(\.path) }
        return []
    }
    #expect(logPaths.allSatisfy { !$0.contains("Netskope") })
    #expect(logPaths.contains { $0.hasSuffix("Editor/old.log") })
}

@Test func guardRefusesCompanySecuritySoftware() throws {
    let box = try Sandbox()
    defer { box.remove() }
    let root = try box.folder("Caches")
    let target = try box.folder("Caches/com.zscaler.Zscaler")
    #expect(PathGuard.check(target, inside: root, identity: FileIdentity.of(target.path), allowedRoots: [root], forbidden: [], mounts: []) == .forbidden)
    #expect(CleanupRoots.isManagedSoftware("Logs/Cisco Secure Client/x.log"))
    #expect(!CleanupRoots.isManagedSoftware("Logs/Editor/x.log"))
}

@Test func testResultBundlesNeedAChoiceWhileTestProductsDoNot() throws {
    let box = try Sandbox()
    defer { box.remove() }
    let workspace = "Library/Developer/XcodeBuildMCP/workspaces/w1"
    try box.file(workspace + "/result-bundles/run.xcresult/Data/blob", bytes: 2_000_000, modified: daysAgo(10))
    try box.file(workspace + "/test-products/App.xctestproducts/blob", bytes: 2_000_000, modified: daysAgo(10))
    let context = ScanContext(home: box.root, now: .now, openFiles: OpenFiles.parse(lsofOutput([])), runningBundleIDs: [], installedBundleIDs: [])

    let found = XcodeCacheScanner.scan(context)
    // Test results do not come back with a rebuild, so they are never ticked for the user; built products are.
    #expect(found.first { $0.name.hasPrefix("result-bundles") }?.verdict.status == .review)
    #expect(found.first { $0.name.hasPrefix("test-products") }?.verdict.status == .ready)
}
