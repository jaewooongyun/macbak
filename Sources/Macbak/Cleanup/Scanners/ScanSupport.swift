import Foundation

/// What every scanner reads besides the disk, collected once per scan. AppKit facts are gathered on the main actor
/// first, so scanners stay plain functions that run off it.
struct ScanContext: Sendable {
    let home: URL
    let now: Date
    /// nil when `lsof` failed: then nothing counts as unused.
    let openFiles: OpenFiles?
    let runningBundleIDs: Set<String>
    /// Bundle ids, among the cache folder names, that LaunchServices knows an installed app for.
    let installedBundleIDs: Set<String>
    /// The ages picked in Settings when the scan started; the whole scan judges by them.
    var ages = CleanupAges()
}

enum ScanSupport {
    static let minimumBytes: Int64 = 1_048_576

    /// The folder with every link resolved, which is the form the path guard accepts; nil when it does not exist.
    /// - Important: nil also when the folder is reached through a link (say `~/Library/Caches` pointing elsewhere), so a
    ///   linked root is never scanned, let alone cleaned.
    static func resolved(_ home: URL, _ relative: String) -> URL? {
        let url = home.appending(path: relative)
        guard let real = PathGuard.realPath(url), PathGuard.isTrusted(url, resolvedTo: real) else { return nil }
        return URL(fileURLWithPath: real, isDirectory: true)
    }

    /// nil when the folder cannot be listed, which callers treat as "could not tell", never as "empty".
    static func children(of folder: URL) -> [URL]? {
        try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
    }

    /// A folder's entries as targets, links left out. The path guard refuses a link anywhere on a target's path, so one
    /// link among the entries (Homebrew keeps one beside each download) made every run skip the whole row. A
    /// link is a few bytes; it stays, dangling, until its tool tidies up.
    static func removals(of children: [URL], root: URL) -> [CleanupTarget] {
        children.filter { (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true }.map { removal($0, root: root) }
    }

    static func removal(_ item: URL, root: URL) -> CleanupTarget {
        CleanupTarget(path: item, root: root, identity: FileIdentity.of(item.path(percentEncoded: false)), action: .removeItem)
    }

    /// Whether a process has anything open below any of `paths`; nil without a snapshot.
    static func isOpen(_ context: ScanContext, _ paths: [URL]) -> Bool? {
        guard let open = context.openFiles else { return nil }
        return paths.contains { open.anyOpen(under: $0.path(percentEncoded: false)) }
    }

    /// "~/dev/project" for row details.
    static func display(_ path: String, home: URL) -> String {
        let homePath = home.path(percentEncoded: false)
        let trimmed = homePath.hasSuffix("/") ? String(homePath.dropLast()) : homePath
        return path.hasPrefix(trimmed + "/") ? "~" + path.dropFirst(trimmed.count) : path
    }

    static func ago(_ date: Date?, now: Date) -> String {
        guard let date else { return "사용 시각 모름" }
        let days = Int(now.timeIntervalSince(date) / 86_400)
        return days < 1 ? "오늘 사용" : "\(days)일 전 사용"
    }
}
