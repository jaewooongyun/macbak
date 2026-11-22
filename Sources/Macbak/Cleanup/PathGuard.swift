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

        // No component below the root may be a link: a link anywhere on the way could lead outside it.
        var path = rootPath
        for part in targetParts[rootParts.count...] {
            path += "/" + part
            var info = stat()
            guard lstat(path, &info) == 0 else { return .unreadable(part) }
            if info.st_mode & S_IFMT == S_IFLNK { return .symbolicLink(part) }
        }

        if CleanupRoots.isManagedSoftware(targetParts.dropFirst(rootParts.count).joined(separator: "/")) { return .forbidden }
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
