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

    static func scan(_ context: ScanContext) -> [CleanupCandidate] {
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

        // The same deep checks a run nobody chose makes before deleting, so a row shown as shallow is not refused then.
        let facts = TreeWalk.inspectAll(found.map(\.item), budget: .seconds(120), alarm: CacheRules.isAlarmName, notice: CacheRules.blocksShallow)
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
        for group in grouped.values { candidates.append(candidate(group, workspace: group[0].workspace, context: context)) }
        for member in members where member.workspace == nil { candidates.append(candidate([member], workspace: nil, context: context)) }
        if !shared.isEmpty { candidates.append(sharedCandidate(shared, context: context)) }
        return candidates.filter { $0.bytes >= ScanSupport.minimumBytes }
    }

    private static func candidate(_ group: [Member], workspace: String?, context: ScanContext) -> CleanupCandidate {
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
