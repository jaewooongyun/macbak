import Darwin
import Foundation

/// The folders a clean-up may delete inside. Everything deleted must sit strictly below one of these.
enum CleanupRoots {
    static func fixed(home: URL) -> [URL] {
        [
            "Library/Developer/Xcode/DerivedData",
            "Library/Developer/XcodeBuildMCP/workspaces",
            "Library/Developer/Xcode/iOS DeviceSupport",
            "Library/Developer/Xcode/tvOS DeviceSupport",
            "Library/Developer/Xcode/watchOS DeviceSupport",
            "Library/Caches",
            "Library/Logs",
        ].map { home.appending(path: $0) }
    }

    /// Each cleanable AI folder is a root of its own: its contents go, the folder stays for the tool to refill.
    static func catalog(home: URL) -> [URL] {
        AITool.catalog.flatMap(\.cleanable).flatMap(\.paths).map { $0.url(home: home) }
    }

    /// Never deleted, nor anything that contains them, whatever a scanner says.
    /// - Important: `~/.cache/uv` holds live virtual environments that running MCP servers execute from, and uv asks to be
    ///   cleaned with its own command; Xcode's UserData holds snippets and key bindings; Archives are build records.
    /// - Note: The SwiftPM cache left this list on 2026-11-03: the user made it a choice ("download again" tier).
    static func forbidden(home: URL) -> [URL] {
        [
            ".cache/uv",
            "Library/Developer/Xcode/UserData",
            "Library/Developer/Xcode/Archives",
        ].map { home.appending(path: $0) }
    }

    static func all(home: URL) -> [URL] { fixed(home: home) + catalog(home: home) }

    /// Folders the cache rules accept right now: each is listed and classified again at deletion time, so a folder that
    /// gained a protected child or the person's files since the scan stops being a root.
    /// - Important: Only folders: a single file would need its parent as a root, which would open the whole parent.
    static func ruleRoots(home: URL) -> [URL] {
        GeneralCacheScanner.classify(home: home)
            .filter { $0.rules.tier == .precheck || $0.rules.tier == .offer || $0.aiPending }
            .filter { !GeneralCacheScanner.commandOnly.contains($0.relative) }
            .filter { (try? $0.url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .compactMap { PathGuard.realPath($0.url).map { URL(fileURLWithPath: $0, isDirectory: true) } }
    }

    /// Company security and device-management software: never offered and never deleted, wherever its files sit.
    /// Matched on any path component, folded, so `~/Library/Logs/Netskope` and
    /// `~/Library/Caches/com.zscaler.Zscaler` are both kept.
    static let managedSoftware = [
        "avast", "jamf", "companyportal", "company portal", "com.microsoft.autoupdate", "com.microsoft.powerlift", "intune",
        "paloaltonetworks", "globalprotect", "f5 vpn", "f5networks", "crowdstrike", "zscaler", "netskope", "sentinelone",
        "kandji", "mosyle", "sophos", "mcafee", "symantec", "forticlient", "com.microsoft.wdav", "tanium", "secureclient", "anyconnect",
    ]

    /// - Note: Also the classifier's wider list (`CacheRules.securitySoftware`: Kaspersky, Bitdefender, Trend Micro and more). With two
    ///   lists, a log folder the classifier kept as security software still went with the 30-day log clean-up.
    static func isManagedSoftware(_ path: String) -> Bool {
        path.split(separator: "/").contains { component in
            let folded = PathKey.fold(String(component))
            return managedSoftware.contains { folded.contains($0) }
        } || CacheRules.securitySoftware(path)
    }
}

/// The only check between a path and its deletion. Every rule fails closed: whatever it cannot confirm is refused.
/// - Note: It narrows, but cannot close, the window in which a checked path is swapped before `removeItem` runs.
///   ponytail: path-based checks; descriptor-relative deletion (`openat`/`unlinkat`) if this ever runs where other users can write.
enum PathGuard {
    enum Refusal: Error, Equatable {
        case rootNotAllowed
        case isRoot
        case notInsideRoot
        case symbolicLink(String)
        case forbidden
        case unreadable(String)
        case containsMount(String)
        case identityChanged
        /// The root itself resolves somewhere other than where it is written: a link would vouch for another folder.
        case rootIsLinked
        /// Not the exact folder its grant names.
        case notGranted
    }

    /// - Parameters:
    ///   - target: the path to delete, built from the resolved root (as scanners do).
    ///   - identity: what `target` was when it was scanned and shown; deletion is refused if it is now another item or
    ///     was modified since (for a folder: an entry directly inside added, removed or renamed).
    ///   - allowedRoots: the roots any deletion may happen inside, usually `CleanupRoots.all(home:)`.
    ///   - mounts: mount points from `mountPoints()`; nil (the list could not be read) refuses everything.
    /// - Returns: nil when the deletion may go ahead.
    /// - Important: Containment compares exactly, after resolving the root. Folding case there would let `/Cache` vouch
    ///   for a different `/cache` on a case-sensitive volume; folding is used only where it can refuse more, never less.
    static func check(_ target: URL, inside root: URL, identity: FileIdentity?, allowedRoots: [URL], forbidden: [URL],
                      mounts: [String]?) -> Refusal? {
        guard let rootPath = realPath(root) else { return .unreadable(root.lastPathComponent) }
        guard isTrusted(root, resolvedTo: rootPath) else { return .rootIsLinked }
        guard let allowed = allowedRoots.first(where: { realPath($0) == rootPath }) else { return .rootNotAllowed }
        // Scanners pass the root already resolved, so trust is judged on the configured entry: if `~/Library/Caches` is
        // a link to `~/Documents`, the resolved `~/Documents` must not be accepted on its behalf.
        guard isTrusted(allowed, resolvedTo: rootPath) else { return .rootIsLinked }

        let rootParts = components(rootPath)
        // Taken as written: `standardizedFileURL` strips a leading `/private` just like `resolvingSymlinksInPath()`.
        // Scanners never write `.` or `..`, so a path holding one is refused rather than interpreted.
        let targetParts = components(target.path(percentEncoded: false))
        guard !targetParts.contains(where: { $0 == "." || $0 == ".." }),
              targetParts.count >= rootParts.count, zip(rootParts, targetParts).allSatisfy(==) else { return .notInsideRoot }
        guard targetParts.count > rootParts.count else { return .isRoot }
        return below(rootPath, rootParts.count, targetParts, identity: identity, forbidden: forbidden, mounts: mounts)
    }

    /// For one folder outside every allowed root that the expanded scan found and judged by itself (`TargetGrant`): only
    /// that exact folder, inside the home, with no link from the home down to it, neither forbidden nor company security
    /// software anywhere on its path below the home, the same item as when scanned, and no volume mounted inside.
    /// - Important: The parent never becomes a root, so nothing beside, above or below the granted folder goes through it.
    static func checkExact(_ target: URL, grant: URL, identity: FileIdentity?, home: URL, forbidden: [URL], mounts: [String]?) -> Refusal? {
        let targetParts = components(target.path(percentEncoded: false))
        guard targetParts == components(grant.path(percentEncoded: false)) else { return .notGranted }
        guard let homePath = realPath(home) else { return .unreadable(home.lastPathComponent) }
        guard isTrusted(home, resolvedTo: homePath) else { return .rootIsLinked }
        let homeParts = components(homePath)
        guard !targetParts.contains(where: { $0 == "." || $0 == ".." }), targetParts.count > homeParts.count,
              zip(homeParts, targetParts).allSatisfy(==) else { return .notInsideRoot }
        return below(homePath, homeParts.count, targetParts, identity: identity, forbidden: forbidden, mounts: mounts)
    }

    /// The checks both share, from a trusted base folder down to the target.
    private static func below(_ basePath: String, _ baseCount: Int, _ targetParts: [String], identity: FileIdentity?, forbidden: [URL],
                              mounts: [String]?) -> Refusal? {
        // No component below the base may be a link: a link anywhere on the way could lead outside it.
        var path = basePath
        for part in targetParts[baseCount...] {
            path += "/" + part
            var info = stat()
            guard lstat(path, &info) == 0 else { return .unreadable(part) }
            if info.st_mode & S_IFMT == S_IFLNK { return .symbolicLink(part) }
        }

        if CleanupRoots.isManagedSoftware(targetParts.dropFirst(baseCount).joined(separator: "/")) { return .forbidden }
        let targetKey = targetParts.map(PathKey.fold)
        for kept in forbidden {
            let keptKey = components(realPath(kept) ?? kept.path(percentEncoded: false)).map(PathKey.fold)
            if isPrefix(keptKey, of: targetKey) || isPrefix(targetKey, of: keptKey) { return .forbidden }
        }

        // Deleting a folder that holds a mount point would empty the other volume too.
        guard let mounts else { return .unreadable("마운트 목록") }
        if let mount = mounts.first(where: { isPrefix(targetParts, of: components($0)) }) { return .containsMount(mount) }

        guard let identity, FileIdentity.of(path) == identity else { return .identityChanged }
        return nil
    }

    /// Every mounted file system's mount point, or nil when the list cannot be read.
    static func mountPoints() -> [String]? {
        var list: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&list, MNT_NOWAIT)
        guard count > 0, let list else { return nil }
        return (0..<Int(count)).map { index in
            withUnsafeBytes(of: list[index].f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        }
    }

    /// A root is trusted when it resolves to where it is written, apart from macOS's own `/var`, `/tmp` and `/etc` links.
    /// If `~/Library/Caches` were a link to `~/Documents`, scanners would offer documents as caches.
    static func isTrusted(_ root: URL, resolvedTo real: String) -> Bool {
        let written = root.path(percentEncoded: false)
        let trimmed = written.count > 1 && written.hasSuffix("/") ? String(written.dropLast()) : written
        if trimmed == real { return true }
        return ["/var/", "/tmp/", "/etc/"].contains { trimmed.hasPrefix($0) } && real == "/private" + trimmed
    }

    /// The absolute path with every link resolved, or nil if it does not exist.
    /// - Note: `URL.resolvingSymlinksInPath()` strips a leading `/private`, which would turn the temporary folder's real
    ///   path back into its `/var` link; `realpath(3)` does not.
    static func realPath(_ url: URL) -> String? {
        guard let resolved = realpath(url.path(percentEncoded: false), nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func components(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    private static func isPrefix(_ prefix: [String], of path: [String]) -> Bool {
        prefix.count <= path.count && zip(prefix, path).allSatisfy(==)
    }
}

/// One folder outside every allowed root that the expanded scan found and judged by itself. The executor deletes exactly
/// it through `PathGuard.checkExact`, after `evaluate` passes again.
/// - Important: `evaluate` is the only judge: the scan's row, `--scan-report`, the executor's first delete and its retry
///   all call it, so what the row promised is what the deletion checks.
struct TargetGrant: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// An Xcode build cache outside the usual places: an `info.plist` naming a workspace, and `Build` or `SourcePackages`.
        case derivedData
        /// A build output git ignores whole in `project`, named in `ProjectDiscovery.outputs` with its marker present.
        case projectArtifact(project: URL)
        /// The `node_modules` beside a `package.json`, of a project left alone longer than the Settings age.
        case nodeModules
        /// A finished AI job's scratch folder: exactly `<jobs>/<id>/<scratch>` of a catalog tool's job store.
        case jobScratch
    }

    let kind: Kind
    let path: URL

    /// What `evaluate` reads besides the folder.
    struct Inputs {
        var now: Date
        var ages: CleanupAges
        /// nil when `lsof` failed: then nothing counts as unused.
        var open: OpenFiles?
        /// Files elsewhere that read package objects from inside the folder now.
        var borrowers: [String]
        /// Whether a package checkout that borrowed its objects from a deleted cache may be proven again from this one.
        var reprove: Bool
        /// The home, for the cache rules' keep list; nil skips them.
        var home: URL?
        /// Reads a file the judge must look inside; the only way it opens one, so a test can see what it reads.
        var read: @Sendable (URL) -> Data? = { try? Data(contentsOf: $0) }
        /// The expanded scan's deadline: past it a folder is not judged at all, and walks and git calls end by it.
        /// nil for the executor, which judges one row at a time.
        var deadline: ContinuousClock.Instant?
    }

    /// Why the folder may not be deleted now, or nil; and the walk, for the row's size and last use.
    static func evaluate(_ grant: TargetGrant, _ inputs: Inputs) -> (refusal: String?, facts: TreeFacts) {
        let deadline = inputs.deadline
        if let deadline, ContinuousClock.now >= deadline { return (ProjectOutputScanner.outOfTime, TreeFacts(gap: "시간 초과")) }
        switch grant.kind {
        case .derivedData:
            let folder = grant.path
            let facts = TreeWalk.inspect(folder, budget: .seconds(120), until: deadline,
                                         alarm: { CacheRules.isAlarmName($0, isFolder: $1, reprove: inputs.reprove, until: deadline) })
            guard let workspace = XcodeCacheScanner.workspacePath(of: folder) else { return ("작업 공간 기록을 읽지 못했습니다", facts) }
            let has = { (name: String) in FileManager.default.fileExists(atPath: folder.appending(path: name).path(percentEncoded: false)) }
            guard has("Build") || has("SourcePackages") else { return ("Xcode 빌드 캐시 모양이 아닙니다", facts) }
            if let alarm = facts.alarm { return (CacheRules.alarmReason(alarm), facts) }
            guard let idle = facts.idle(at: inputs.now) else { return ("다 훑지 못해 마지막 사용 시각을 모릅니다", facts) }
            if idle < inputs.ages.seconds(.buildCache) { return ("최근에 썼습니다.", facts) }
            guard let open = inputs.open else { return ("열린 파일을 확인하지 못했습니다", facts) }
            let project = URL(fileURLWithPath: workspace).deletingLastPathComponent().path(percentEncoded: false)
            if open.anyOpen(under: folder.path(percentEncoded: false)) || open.anyOpen(under: project) { return ("지금 쓰는 파일이 있습니다", facts) }
            if !inputs.borrowers.isEmpty { return ("다른 캐시가 이 캐시의 패키지 기록을 빌려 씁니다", facts) }
            return (nil, facts)
        case .projectArtifact(let project):
            let folder = grant.path
            let facts = TreeWalk.inspect(folder, budget: .seconds(60), until: deadline,
                                         alarm: { CacheRules.isAlarmName($0, isFolder: $1, reprove: false, until: deadline) })
            guard ProjectDiscovery.hasMarker(folder.lastPathComponent, project: project, folder: folder) else {
                return ("이 이름을 만드는 도구의 프로젝트 파일이 없습니다", facts)
            }
            switch Git.isIgnored(folder, project: project, until: deadline) {
            case nil: return ("git으로 확인하지 못했습니다", facts)
            case false?: return ("git이 추적하거나 무시하지 않는 폴더입니다", facts)
            case true?: break
            }
            // Relative to the home where the rules can read it, as the general scan asks them.
            if let home = inputs.home {
                let relative = String(ProjectDiscovery.key(folder).dropFirst(ProjectDiscovery.key(home).count + 1))
                let listing = CacheRules.listing(home: home, relative: relative)
                let rules = CacheRules.tier(path: relative, inside: listing.inside, beside: listing.beside, home: home)
                if rules.tier == .keep { return (CacheRules.protectedReason(rules), facts) }
            }
            if let alarm = facts.alarm { return (CacheRules.alarmReason(alarm), facts) }
            guard let idle = facts.idle(at: inputs.now) else { return ("다 훑지 못해 마지막 사용 시각을 모릅니다", facts) }
            if idle < inputs.ages.seconds(.general) { return ("최근에 썼습니다.", facts) }
            guard let open = inputs.open else { return ("열린 파일을 확인하지 못했습니다", facts) }
            if open.anyOpen(under: folder.path(percentEncoded: false)) { return ("지금 쓰는 파일이 있습니다", facts) }
            return (nil, facts)
        case .nodeModules:
            return NodeModules.refusal(grant.path, inputs)
        case .jobScratch:
            return JobScratch.refusal(grant.path, inputs)
        }
    }
}
