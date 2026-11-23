import Foundation
import Testing
@testable import Macbak

/// `node_modules` of a project left alone longer than the Settings age (60 days by default), found by the expanded walk
/// and judged by its grant. A workspace member, a hand-patched package or a recent install keeps it.
@Suite struct NodeModulesTests {
    /// A project at `path` with `package.json` (its JSON), one 2 MB package and every date `age` days back.
    @discardableResult
    static func project(_ box: Sandbox, _ path: String, json: String = #"{"name": "app"}"#, age: Double = 61) throws -> URL {
        try box.file(path + "/src/index.js", modified: daysAgo(age))
        try box.file(path + "/node_modules/left-pad/index.js", bytes: 2_000_000, modified: daysAgo(age))
        try json.write(to: box.root.appending(path: path + "/package.json"), atomically: true, encoding: .utf8)
        for item in ["package.json", "src", "node_modules", "node_modules/left-pad"] {
            try FileManager.default.setAttributes([.modificationDate: daysAgo(age)], ofItemAtPath: box.root.appending(path: path + "/" + item).path)
        }
        return box.root.appending(path: path + "/node_modules")
    }

    static func age(_ box: Sandbox, _ path: String, _ days: Double = 61) throws {
        try FileManager.default.setAttributes([.modificationDate: daysAgo(days)], ofItemAtPath: box.root.appending(path: path).path)
    }

    static func reasons(_ box: Sandbox, ages: CleanupAges = CleanupAges(), open: [String] = []) -> [String: String] {
        let found = ProjectDiscovery.walk(home: box.root).nodeModules
        var context = ProjectDiscoveryTests.context(box.root, open: open)
        context.ages = ages
        return Dictionary(uniqueKeysWithValues: ProjectOutputScanner.nodeModulesRows(found, context: context).map { row in
            (String(row.targets[0].path.path.dropFirst(box.root.path.count + 1)), row.isSelectable ? "후보" : row.verdict.reason)
        })
    }

    @Test func aProjectLeftAloneLongOffersItsPackagesOnlyByHand() throws {
        let box = try Sandbox()
        defer { box.remove() }
        try Self.project(box, "dev/app")
        #expect(Self.reasons(box) == ["dev/app/node_modules": "후보"])
        let row = try #require(ProjectOutputScanner.nodeModulesRows(ProjectDiscovery.walk(home: box.root).nodeModules,
                                                                    context: ProjectDiscoveryTests.context(box.root)).first)
        #expect(row.manualOnly && !row.isPreselected && !row.isShallow && row.targets[0].grant?.kind == .nodeModules)
        #expect(row.guards.watchPaths.map(\.path) == [box.root.appending(path: "dev/app").path])
        var longer = CleanupAges()
        longer[.nodeModules] = 90
        #expect(Self.reasons(box, ages: longer) == ["dev/app/node_modules": "최근에 쓰거나 설치했습니다."])
    }

    @Test func aRecentInstallOrEditKeepsIt() throws {
        let box = try Sandbox()
        defer { box.remove() }
        try Self.project(box, "dev/a")
        try box.file("dev/a/node_modules/.package-lock.json", modified: .now)
        try Self.age(box, "dev/a/node_modules")
        // A package installed again in place: only its own folder moves, not `node_modules`.
        try Self.project(box, "dev/b")
        try FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: box.root.appending(path: "dev/b/node_modules/left-pad").path)
        try Self.project(box, "dev/c")
        try box.file("dev/c/src/edited.js", modified: .now)
        let reasons = Self.reasons(box)
        #expect(reasons["dev/a/node_modules"] == "최근에 쓰거나 설치했습니다.")
        #expect(reasons["dev/b/node_modules"] == "최근에 쓰거나 설치했습니다.")
        #expect(reasons["dev/c/node_modules"] == "최근에 쓰거나 설치했습니다.")
    }

    @Test func aHandPatchedPackageAnywhereUpTheProjectKeepsIt() throws {
        let box = try Sandbox()
        defer { box.remove() }
        // Each in a tree of its own, so one project's marker cannot stand for another's.
        try Self.project(box, "dev/p1/app")
        try box.folder("dev/p1/app/patches")
        try Self.project(box, "dev/p2/app")
        try box.folder("dev/p2/app/.yarn/patches")
        try Self.project(box, "dev/p3/app")
        try box.folder("dev/p3/.patches")
        try Self.project(box, "dev/p4/app", json: #"{"patchedDependencies": {"a@1": "p.patch"}}"#)
        try Self.project(box, "dev/p5/app", json: #"{"pnpm": {"patchedDependencies": {"a@1": "p.patch"}}}"#)
        try Self.project(box, "dev/p6/app")
        try "patchedDependencies:\n  a@1: p.patch\n".write(to: box.root.appending(path: "dev/p6/app/pnpm-workspace.yaml"), atomically: true, encoding: .utf8)
        try Self.project(box, "dev/p7/app")
        for folder in ["dev/p1/app", "dev/p2/app", "dev/p3", "dev/p3/app", "dev/p6/app"] { try Self.age(box, folder) }
        let reasons = Self.reasons(box)
        #expect(reasons.count == 7 && reasons["dev/p7/app/node_modules"] == "후보")
        for index in 1...6 { #expect(reasons["dev/p\(index)/app/node_modules"] == "직접 고친 패키지 기록이 있습니다") }
    }

    @Test func aWorkspaceMemberIsKeptAndOnlyTheRootOffered() throws {
        let box = try Sandbox()
        defer { box.remove() }
        try Self.project(box, "dev/mono", json: #"{"workspaces": ["packages/*"]}"#)
        try Self.project(box, "dev/mono/packages/a")
        try Self.project(box, "dev/pn")
        try "packages:\n  - 'packages/*'\n".write(to: box.root.appending(path: "dev/pn/pnpm-workspace.yaml"), atomically: true, encoding: .utf8)
        try Self.project(box, "dev/pn/packages/b")
        try Self.project(box, "dev/le")
        try "{}".write(to: box.root.appending(path: "dev/le/lerna.json"), atomically: true, encoding: .utf8)
        try Self.project(box, "dev/le/packages/c")
        for folder in ["dev/mono", "dev/mono/packages", "dev/pn", "dev/pn/packages", "dev/le", "dev/le/packages"] { try Self.age(box, folder) }
        let reasons = Self.reasons(box)
        #expect(reasons["dev/mono/node_modules"] == "후보")
        for member in ["dev/mono/packages/a", "dev/pn/packages/b", "dev/le/packages/c"] {
            #expect(reasons[member + "/node_modules"] == "워크스페이스 멤버라 루트에서 함께 설치합니다")
        }
    }

    @Test func aWorkspaceAboveTheRepositoryIsNotItsBusiness() throws {
        let box = try Sandbox()
        defer { box.remove() }
        try Self.project(box, "dev/outer", json: #"{"workspaces": ["*"]}"#)
        try Self.project(box, "dev/outer/repo")
        try box.folder("dev/outer/repo/.git")
        try Self.age(box, "dev/outer/repo")
        try Self.age(box, "dev/outer")
        #expect(Self.reasons(box)["dev/outer/repo/node_modules"] == "후보")
    }

    @Test func anOpenFileOrALinkKeepsIt() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let open = try Self.project(box, "dev/open")
        try Self.project(box, "dev/linked")
        let real = try Self.project(box, "store/real")
        try FileManager.default.removeItem(at: box.root.appending(path: "dev/linked/node_modules"))
        _ = try box.link("dev/linked/node_modules", to: real)
        let reasons = Self.reasons(box, open: [open.appending(path: "left-pad/index.js").path])
        #expect(reasons["dev/open/node_modules"] == "지금 쓰는 파일이 있습니다")
        #expect(reasons["dev/linked/node_modules"] == "링크이거나 읽을 수 없습니다")
    }

    @Test func aChangeAfterTheScanStopsTheDelete() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        for name in ["gone", "patched", "kept"] { try Self.project(box, "dev/\(name)") }
        let rows = ProjectOutputScanner.nodeModulesRows(ProjectDiscovery.walk(home: box.root).nodeModules, context: ProjectDiscoveryTests.context(box.root))
            .map { row in var row = row; row.scannedAt = .now; return row }
        #expect(rows.count == 3 && rows.allSatisfy(\.isSelectable))
        try FileManager.default.removeItem(at: box.root.appending(path: "dev/gone/package.json"))
        try box.folder("dev/patched/patches")
        let executor = fixtureExecutor(roots: [], audit: box.root.appending(path: "audit.jsonl")) { $0.home = box.root }
        let report = await executor.run(rows) { _ in }
        let outcomes = Dictionary(uniqueKeysWithValues: report.items.map { ($0.name.components(separatedBy: " ·").first ?? "", $0.outcome) })
        #expect(outcomes["gone"] == .skipped("package.json 을 읽지 못했습니다"))
        #expect(outcomes["patched"] == .skipped("직접 고친 패키지 기록이 있습니다"))
        #expect(outcomes["kept"] == .deleted)
        #expect(FileManager.default.fileExists(atPath: box.root.appending(path: "dev/gone/node_modules").path))
        #expect(FileManager.default.fileExists(atPath: box.root.appending(path: "dev/patched/node_modules").path))
    }
}
