import Foundation

/// Xcode build caches, one row per workspace: its Xcode DerivedData, its XcodeBuildMCP DerivedData and its
/// xcode-build-server folder go together, because a half-deleted cache breaks the next build.
/// - Important: Protection reaches the whole group. A file open anywhere in it, or in the workspace's own folder (Xcode,
///   an editor or a shell working there), keeps every member.
/// - Note: "The workspace is gone" is concluded only from a recorded `WorkspacePath` that no longer exists. A cache with
///   no record has no workspace folder to watch, so only its own files and the one-day rule keep it; untouched longer, it
///   goes with the shallow clean-up like the others (the person's decision, 2026-11-04).
enum XcodeCacheScanner {
    /// Caches every build shares, at the top of a DerivedData folder.
    static let sharedNames: Set<String> = [
        "CompilationCache.noindex", "SymbolCache.noindex", "SDKStatCaches.noindex", "SDKExplicitPrecompiledModules", "ModuleCache.noindex",
    ]
    private struct Member {
        let target: CleanupTarget
        let facts: TreeFacts
        let workspace: String?
        let label: String
    }

    static func scan(_ context: ScanContext) -> [CleanupCandidate] { scan(context, reproving: nil, reprove: false) }

    /// The rows of every workspace group holding one of `caches`, rebuilt whole (each member, its targets and guards).
    /// With `reprove`, the package proof may borrow objects from inside each cache, and each row is a choice only:
    /// `manualOnly`, `reproved`.
    /// - Important: Expanded scan only. It costs git calls per package file the usual scan must not add.
    static func scan(_ context: ScanContext, only caches: Set<String>, reprove: Bool) -> [CleanupCandidate] {
        let keys = Set(caches.map { PathKey.fold(PathGuard.realPath(URL(fileURLWithPath: $0)) ?? $0) })
        return scan(context, reproving: keys, reprove: reprove).map { row in
            guard reprove else { return row }
            var row = row
            row.manualOnly = true
            row.reproved = true
            row.trusted = false
            return row
        }
    }

    /// The build caches in the usual places, Xcode's and XcodeBuildMCP's, without the shared compiler caches.
    static func standardCaches(_ home: URL) -> [URL] {
        var caches: [URL] = []
        if let root = ScanSupport.resolved(home, "Library/Developer/Xcode/DerivedData") { caches += ScanSupport.children(of: root) ?? [] }
        if let root = ScanSupport.resolved(home, "Library/Developer/XcodeBuildMCP/workspaces") {
            for workspace in ScanSupport.children(of: root) ?? [] { caches += ScanSupport.children(of: workspace.appending(path: "DerivedData")) ?? [] }
        }
        return caches.filter { !sharedNames.contains($0.lastPathComponent) }
    }

    private static func scan(_ context: ScanContext, reproving: Set<String>?, reprove: Bool) -> [CleanupCandidate] {
        // First list what to look at (cheap), then walk it all at once (the slow part).
        var found: [(item: URL, root: URL, label: String, workspace: String?)] = []
        if let root = ScanSupport.resolved(context.home, "Library/Developer/Xcode/DerivedData") {
            for item in ScanSupport.children(of: root) ?? [] { found.append((item, root, "Xcode", workspacePath(of: item))) }
        }
        if let root = ScanSupport.resolved(context.home, "Library/Developer/XcodeBuildMCP/workspaces") {
            for workspace in ScanSupport.children(of: root) ?? [] {
                for item in ScanSupport.children(of: workspace.appending(path: "DerivedData")) ?? [] {
                    found.append((item, root, "MCP", workspacePath(of: item)))
                }
                // Test products and result bundles carry no workspace record; they stand alone.
                for name in ["test-products", "result-bundles"] {
                    let item = workspace.appending(path: name)
                    guard FileManager.default.fileExists(atPath: item.path(percentEncoded: false)) else { continue }
                    found.append((item, root, "MCP \(name)", nil))
                }
            }
        }
        // xcode-build-server names its folders after the worktree path with "/" turned into "-".
        if let caches = ScanSupport.resolved(context.home, "Library/Caches") {
            let workspaces = found.compactMap { sharedNames.contains($0.item.lastPathComponent) ? nil : $0.workspace }
            let byKey = Dictionary(workspaces.map { (buildServerKey(for: $0), $0) }, uniquingKeysWith: { first, _ in first })
            for item in ScanSupport.children(of: caches.appending(path: "xcode-build-server")) ?? [] {
                found.append((item, caches, "빌드 서버", byKey[PathKey.fold(item.lastPathComponent)]))
            }
        }

        // Who borrows package objects from whom, from every build cache listed here and the remembered borrowers.
        let caches = found.filter { ($0.label == "Xcode" || $0.label == "MCP") && !sharedNames.contains($0.item.lastPathComponent) }.map(\.item)
        let lending = lendingMap(caches: caches, memory: context.borrowerMemory)

        if let reproving {
            // Whole groups: a member that holds a broken checkout brings every other member of its workspace, so their
            // own protection (recent use, open files) and targets stay with the row.
            func key(_ url: URL) -> String { PathKey.fold(PathGuard.realPath(url) ?? url.path(percentEncoded: false)) }
            let hit = found.filter { reproving.contains(key($0.item)) }
            let workspaces = Set(hit.compactMap { $0.workspace.map(PathKey.fold) })
            found = found.filter { entry in
                !sharedNames.contains(entry.item.lastPathComponent)
                    && (reproving.contains(key(entry.item)) || entry.workspace.map { workspaces.contains(PathKey.fold($0)) } ?? false)
            }
        }
        // The same deep checks a run nobody chose makes before deleting, so a row shown as shallow is not refused then.
        let facts = TreeWalk.inspectAll(found.map(\.item), budget: .seconds(120),
                                        alarm: { CacheRules.isAlarmName($0, isFolder: $1, reprove: reprove) },
                                        notice: { CacheRules.blocksShallow($0, reprove: reprove) })
        var members: [Member] = []
        var shared: [Member] = []
        for (entry, facts) in zip(found, facts) {
            let isShared = sharedNames.contains(entry.item.lastPathComponent)
            let member = Member(target: ScanSupport.removal(entry.item, root: entry.root), facts: facts,
                                workspace: isShared ? nil : entry.workspace, label: entry.label)
            if isShared { shared.append(member) } else { members.append(member) }
        }

        var candidates: [CleanupCandidate] = []
        let grouped = Dictionary(grouping: members.filter { $0.workspace != nil }) { PathKey.fold($0.workspace!) }
        for group in grouped.values { candidates.append(candidate(group, workspace: group[0].workspace, context: context, lending: lending)) }
        for member in members where member.workspace == nil {
            candidates.append(candidate([member], workspace: nil, context: context, lending: lending))
        }
        if !shared.isEmpty { candidates.append(sharedCandidate(shared, context: context)) }
        // A memory that does not read: a lender's borrower may be somewhere this scan did not look, so nothing here goes
        // without a person picking it. The next scan writes the memory again.
        if lending.memoryCorrupt { for index in candidates.indices { candidates[index].manualOnly = true } }
        return candidates.filter { $0.bytes >= ScanSupport.minimumBytes }
    }

    /// Lenders and their live borrowers, and the caches holding a fully broken checkout.
    struct Lending: Sendable {
        var borrowers: [String: Set<String>] = [:]
        var broken: Set<String> = []
        var memoryCorrupt = false

        /// Borrowers of `cache` outside `row`'s own targets.
        func outside(_ cache: URL, row: [URL]) -> Set<String> {
            let key = PathGuard.realPath(cache) ?? cache.path(percentEncoded: false)
            let inside = row.map { PathKey.fold((PathGuard.realPath($0) ?? $0.path(percentEncoded: false)) + "/") }
            return borrowers.filter { CheckoutAlternates.same($0.key, key) }.values.reduce(into: Set<String>()) { $0.formUnion($1) }
                .filter { file in !inside.contains { PathKey.fold(file).hasPrefix($0) } }
        }
    }

    /// Reads the caches' alternates, rechecks and merges the remembered borrowers, and writes the memory back.
    static func lendingMap(caches: [URL], memory: BorrowerMemory?) -> Lending {
        let map = CheckoutAlternates.read(caches: caches)
        var lending = Lending(borrowers: map.borrowers, broken: map.broken)
        guard let memory else { return lending }
        let state = memory.load()
        lending.memoryCorrupt = state == .corrupt
        let (live, gone) = BorrowerMemory.recheck(state.known)
        for edge in live { lending.borrowers[edge.lender, default: []].insert(edge.borrower) }
        let seen = Set(map.borrowers.flatMap { lender, files in files.map { BorrowerMemory.Edge(lender: lender, borrower: $0) } })
        memory.commit(seen: seen, gone: gone)
        return lending
    }

    private static func candidate(_ unordered: [Member], workspace: String?, context: ScanContext, lending: Lending) -> CleanupCandidate {
        // A member that lends to another member goes last, so the borrower is gone before its lender is.
        let paths = unordered.map(\.target.path)
        let lends = { (member: Member) in !lending.outside(member.target.path, row: []).subtracting(lending.outside(member.target.path, row: paths)).isEmpty }
        let group = unordered.filter { !lends($0) } + unordered.filter(lends)
        let complete = group.allSatisfy(\.facts.isComplete)
        let newest = group.compactMap(\.facts.newest).max()
        let idle = newest.map { context.now.timeIntervalSince($0) }
        let exists = workspace.map { FileManager.default.fileExists(atPath: $0) }

        var watched = group.map(\.target.path)
        if let workspace, exists == true { watched.append(URL(fileURLWithPath: workspace).deletingLastPathComponent()) }
        var evidence = Evidence(verified: complete && idle != nil ? true : nil, inUse: ScanSupport.isOpen(context, watched), regenerable: true)
        // The person's rule for build caches (Settings, one day by default): one touched within it is being worked on; one
        // untouched longer goes, since the next build makes it again. Open files and a running Xcode still protect it.
        if let idle, idle < context.ages.seconds(.buildCache) { evidence.recentlyUsed = true }
        // Test results and their attachments: a rebuild does not bring the same run back, so a person chooses.
        if group.contains(where: { $0.label == "MCP result-bundles" }) { evidence.userData = true }
        if let alarm = group.lazy.compactMap(\.facts.alarm).first { evidence.protectedReason = CacheRules.alarmReason(alarm) }
        // Another cache reads package objects from one of these: deleting it would break that cache's checkouts.
        let borrowers = Set(group.flatMap { lending.outside($0.target.path, row: paths) }.map { PathKey.fold(CheckoutAlternates.cache(ofBorrower: $0)) })
        if !borrowers.isEmpty { evidence.protectedReason = "다른 캐시 \(borrowers.count)개가 이 캐시의 패키지 기록을 빌려 씁니다." }

        let bytes = group.reduce(Int64(0)) { $0 + $1.facts.bytes }
        let name: String
        var parts: [String] = []
        if let workspace {
            let url = URL(fileURLWithPath: workspace)
            name = "\(url.deletingLastPathComponent().lastPathComponent) · \(url.deletingPathExtension().lastPathComponent)"
            parts.append(ScanSupport.display(url.deletingLastPathComponent().path(percentEncoded: false), home: context.home))
            if exists == false { parts.append("작업 공간이 지워짐") }
        } else {
            name = "\(group[0].target.path.lastPathComponent) (\(group[0].label))"
            parts.append("어느 작업 공간인지 기록 없음")
        }
        parts.insert(Set(group.map(\.label)).sorted().joined(separator: "·") + " 캐시", at: 0)
        parts.append(ScanSupport.ago(newest, now: context.now))
        var row = CleanupCandidate(id: "xcode." + (workspace.map(PathKey.fold) ?? group[0].target.path.path(percentEncoded: false)),
                                   name: name, detail: parts.joined(separator: " · "), symbol: "hammer", bytes: bytes,
                                   evidence: evidence, lowerBound: !complete, targets: group.map(\.target), lastUsed: newest,
                                   guards: CleanupGuards(watchPaths: Array(watched.dropFirst(group.count))))
        // Build caches Xcode makes again by itself; a group holding test results or a document is never vouched for.
        row.trusted = !evidence.userData && group.allSatisfy { $0.facts.noticed == nil }
        return row
    }

    /// The shared compiler caches: kept while Xcode runs, anything in them is open, or they changed within the build-cache age.
    private static func sharedCandidate(_ group: [Member], context: ScanContext) -> CleanupCandidate {
        let complete = group.allSatisfy(\.facts.isComplete)
        let newest = group.compactMap(\.facts.newest).max()
        var inUse = ScanSupport.isOpen(context, group.map(\.target.path))
        if context.runningBundleIDs.contains("com.apple.dt.Xcode") { inUse = true }
        var evidence = Evidence(verified: complete && newest != nil ? true : nil, inUse: inUse, regenerable: true)
        if let newest, context.now.timeIntervalSince(newest) < context.ages.seconds(.buildCache) { evidence.recentlyUsed = true }
        if let alarm = group.lazy.compactMap(\.facts.alarm).first { evidence.protectedReason = CacheRules.alarmReason(alarm) }
        var row = CleanupCandidate(id: "xcode.shared", name: "Xcode 공용 컴파일 캐시", detail: "모든 프로젝트가 함께 씀 · \(group.count)개 폴더 · \(ScanSupport.ago(newest, now: context.now))",
                                   symbol: "hammer.circle", bytes: group.reduce(0) { $0 + $1.facts.bytes }, evidence: evidence,
                                   lowerBound: !complete, targets: group.map(\.target), lastUsed: newest,
                                   guards: CleanupGuards(bundleIDs: ["com.apple.dt.Xcode"]))
        row.trusted = group.allSatisfy { $0.facts.noticed == nil }
        return row
    }

    /// The workspace a DerivedData folder belongs to, from its `info.plist`; nil when there is no readable record.
    static func workspacePath(of cache: URL) -> String? {
        guard let data = try? Data(contentsOf: cache.appending(path: "info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let path = plist["WorkspacePath"] as? String, path.hasPrefix("/") else { return nil }
        return path
    }

    /// "/Users/me/dev/app/x.xcworkspace" → "-users-me-dev-app", folded like folder names on APFS.
    static func buildServerKey(for workspace: String) -> String {
        // NSString path functions drop the trailing "/" that `URL.path(percentEncoded:)` keeps on folders.
        PathKey.fold((workspace as NSString).deletingLastPathComponent.replacingOccurrences(of: "/", with: "-"))
    }
}
