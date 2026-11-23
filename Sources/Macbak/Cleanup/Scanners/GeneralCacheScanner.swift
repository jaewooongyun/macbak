import Foundation

/// Everything the other scanners do not cover, sorted by the cache rules: developer tool folders (Gradle, Android, npm,
/// pip, uv, CocoaPods, ...), caches inside Application Support (Chromium, Electron), sandbox container caches and a
/// few Xcode and simulator folders. One row per folder; its contents are offered and the folder itself stays.
/// - Important: The rules decide alone here. Their "don't know" is protected until the on-device model has looked, and
///   only items inside ``CacheRules/modelAreas`` are ever shown to the model (`aiPending`).
/// - Note: Rows that the tool says to clean only with its own command (`uv cache prune`) get no targets: the command is
///   shown instead.
enum GeneralCacheScanner {
    /// Folder patterns, relative to the home folder, whose children are candidates.
    static let patterns = [
        ".cache/*", ".cache/huggingface/*", ".[!.]*/*", ".gradle/caches/*", "go/pkg/*", "Library/pnpm/*",
        "Library/Application Support/*/*", "Library/Containers/*/Data/Library/Caches/*", "Library/Group Containers/*/Library/Caches/*",
        "Library/Developer/Xcode/*", "Library/Developer/CoreSimulator/*", "Library/Android/sdk/*",
    ]
    /// What other scanners own, so nothing is offered twice: app caches and old logs, Xcode build caches, device support
    /// and simulators.
    static let ownedElsewhere = [
        "Library/Caches/", "Library/Logs/", "Library/Developer/Xcode/DerivedData", "Library/Developer/XcodeBuildMCP",
        "Library/Developer/Xcode/iOS DeviceSupport", "Library/Developer/Xcode/watchOS DeviceSupport",
        "Library/Developer/Xcode/tvOS DeviceSupport", "Library/Developer/Xcode/visionOS DeviceSupport",
        "Library/Developer/CoreSimulator/Devices",
        // The Trash holds what the person deleted; emptying it is its own, separate action.
        ".Trash",
    ]
    /// Folders the tool says must be cleaned with its own command, never by deleting files.
    static let commandOnly = [".cache/uv"]

    struct Found {
        let relative: String
        let url: URL
        let inside: String
        let beside: String
        let rules: CacheRules.Verdict
        let aiPending: Bool
    }

    static func scan(_ context: ScanContext) -> [CleanupCandidate] {
        let found = classify(context)
        let facts = TreeWalk.inspectAll(found.map(\.url), budget: .seconds(60), alarm: CacheRules.isAlarmName, notice: CacheRules.blocksShallow)
        return zip(found, facts).compactMap { candidate($0, $1, context) }
    }

    /// Lists and classifies every candidate (names only), dropping a folder whose own descendant is also listed so the
    /// finer rows win, as with Gradle's build cache beside its dependency cache.
    static func classify(_ context: ScanContext) -> [Found] { classify(home: context.home) }

    static func classify(home: URL) -> [Found] {
        let claimed = aiClaimed(home: home)
        var relatives = Set<String>()
        for pattern in patterns {
            for relative in expand(pattern, home: home) {
                if ownedElsewhere.contains(where: { relative == $0 || relative.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }) { continue }
                if CleanupRoots.isManagedSoftware(relative) { continue }
                let folded = PathKey.fold(home.appending(path: relative).path(percentEncoded: false))
                if claimed.contains(where: { folded == $0 || folded.hasPrefix($0 + "/") }) { continue }
                relatives.insert(relative)
            }
        }
        var found: [Found] = []
        let homeReal = PathGuard.realPath(home)
        for relative in relatives.sorted() {
            let url = home.appending(path: relative)
            // A link anywhere on the way, the item or a parent such as ~/.cache, could lead to what the rules never
            // looked at; the deletion root would then be the link's target. Skipped, like a linked clean-up root.
            guard let homeReal, noLink(from: homeReal, through: relative) else { continue }
            let listing = CacheRules.listing(home: home, relative: relative)
            let rules = CacheRules.tier(path: relative, inside: listing.inside, beside: listing.beside, home: home)
            let pending = rules.tier == .model && CacheRules.modelMayOffer(path: relative, inside: listing.inside)
            found.append(Found(relative: relative, url: url, inside: listing.inside, beside: listing.beside, rules: rules, aiPending: pending))
        }
        let offered = found.filter { $0.rules.tier != .keep }.map(\.relative)
        return found.filter { item in
            item.rules.tier == .keep || !offered.contains(where: { $0.hasPrefix(item.relative + "/") })
        }
    }

    private static func candidate(_ item: Found, _ facts: TreeFacts, _ context: ScanContext) -> CleanupCandidate? {
        let tier = item.rules.tier
        // A single file would need its parent folder as a deletion root, which opens the whole parent; files are only
        // listed when they are kept, so the person sees why.
        let isFolder = (try? item.url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        if !isFolder && tier != .keep && tier != .model { return nil }
        // Tiny rows only clutter the offer; protected ones are listed whatever their size, so the person sees what is kept.
        if tier != .keep && tier != .model && facts.isComplete && facts.bytes < ScanSupport.minimumBytes { return nil }
        var evidence = Evidence(verified: facts.isComplete && facts.newest != nil ? true : nil,
                                inUse: ScanSupport.isOpen(context, [item.url]), regenerable: true)
        // The user's rule (Settings, three days by default): anything changed within it is being worked on.
        if let idle = facts.idle(at: context.now), idle < context.ages.seconds(.general) { evidence.recentlyUsed = true }
        switch tier {
        case .precheck: break
        case .offer:
            evidence.downloadCost = true
            evidence.costReason = CacheRules.costReason(item.rules)
        case .keep: evidence.protectedReason = CacheRules.protectedReason(item.rules)
        case .model:
            evidence.protectedReason = item.aiPending ? "기기 AI가 확인하기 전까지 지우지 않습니다." : CacheRules.protectedReason(item.rules)
        }
        // A key or disk image deep inside keeps the row whatever the rules said from the first names, and the model
        // never gets to look at it.
        let alarm = tier == .keep ? nil : facts.alarm
        if let alarm { evidence.protectedReason = CacheRules.alarmReason(alarm) }

        let command = commandOnly.contains(item.relative) ? item.rules.devRow?.command : nil
        var targets: [CleanupTarget] = []
        if command == nil, alarm == nil, isFolder, tier == .precheck || tier == .offer || item.aiPending {
            targets = removals(item.url)
        }
        var detail = ["~/" + item.relative, ScanSupport.ago(facts.newest, now: context.now)]
        if let command { detail.append("터미널에서 `\(command)`로 정리하세요") }

        var row = CleanupCandidate(
            id: "general." + PathKey.fold(item.relative), name: (item.relative as NSString).lastPathComponent,
            detail: detail.joined(separator: " · "), symbol: symbol(for: item), bytes: facts.bytes, evidence: evidence,
            lowerBound: !facts.isComplete, targets: targets, lastUsed: facts.newest,
            guards: CleanupGuards(watchPaths: [item.url]))
        row.toolCommand = command ?? (item.rules.devRow?.command.isEmpty == false ? item.rules.devRow?.command : nil)
        row.trusted = (CacheRules.rebuildsLocally(item.rules, path: item.relative) || isAppCache(item)) && facts.noticed == nil
        if item.aiPending, alarm == nil {
            row.exploreInput = ExploreInput(url: item.url, relative: item.relative, inside: item.inside, beside: item.beside)
        }
        return row
    }

    /// The folder's contents; the folder stays, since tools expect it to exist. The folder is the deletion root, which
    /// the executor accepts only if the rules still accept it then (`CleanupRoots.ruleRoots`).
    private static func removals(_ url: URL) -> [CleanupTarget] {
        guard let real = PathGuard.realPath(url).map({ URL(fileURLWithPath: $0, isDirectory: true) }),
              let inside = ScanSupport.children(of: real) else { return [] }
        return ScanSupport.removals(of: inside, root: real)
    }

    private static func symbol(for item: Found) -> String {
        if item.aiPending { return "sparkle.magnifyingglass" }
        let path = item.relative
        if path.hasPrefix(".gradle") || path.hasPrefix(".android") || path.hasPrefix("Library/Android") { return "hammer" }
        if path.hasPrefix("Library/Developer") { return "hammer" }
        if path.hasPrefix(".npm") || path.hasPrefix(".yarn") || path.hasPrefix(".bun") || path.hasPrefix("Library/pnpm") { return "shippingbox" }
        if path.hasPrefix(".cache") { return "archivebox" }
        if path.contains("/Logs") || path.hasSuffix("logs") { return "doc.text" }
        return "folder"
    }

    /// A glob with `*` (and the `.[!.]*` dot-folder form) over folder names, one level per component.
    static func expand(_ pattern: String, home: URL) -> [String] {
        var current = [""]
        for component in pattern.split(separator: "/").map(String.init) {
            var next: [String] = []
            for prefix in current {
                if !component.contains("*") {
                    next.append(prefix.isEmpty ? component : prefix + "/" + component)
                    continue
                }
                let folder = home.appending(path: prefix).path(percentEncoded: false)
                for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] where matches(name, component) {
                    next.append(prefix.isEmpty ? name : prefix + "/" + name)
                }
            }
            current = next
        }
        return current.filter { FileManager.default.fileExists(atPath: home.appending(path: $0).path(percentEncoded: false)) }
    }

    private static func matches(_ name: String, _ component: String) -> Bool {
        switch component {
        case "*": !name.hasPrefix(".")
        case ".[!.]*": name.hasPrefix(".") && !name.hasPrefix("..") && name.count > 1
        default: false
        }
    }

    /// An app's own cache folder, where the platform's convention is that it comes back by itself: a sandboxed app's
    /// Caches (its Library/Caches) and a Chromium or Electron app's cache folders. A ready one joins the shallow
    /// clean-up like the app caches. Not ~/.cache: an unknown tool's folder there may hold downloads it cannot rebuild.
    static func isAppCache(_ item: Found) -> Bool {
        isContainerCache(item.relative) || item.rules.why == "chromium cache"
    }

    /// `Library/Containers/<app>/Data/Library/Caches/<name>` or `Library/Group Containers/<group>/Library/Caches/<name>`.
    static func isContainerCache(_ relative: String) -> Bool {
        let parts = relative.split(separator: "/").map(String.init)
        if parts.count == 7, parts[0] == "Library", parts[1] == "Containers", parts[3] == "Data", parts[4] == "Library", parts[5] == "Caches" { return true }
        return parts.count == 6 && parts[0] == "Library" && parts[1] == "Group Containers" && parts[3] == "Library" && parts[4] == "Caches"
    }

    /// Every component below `root` exists and none is a link. Checked one by one with `lstat`, not by comparing the
    /// resolved path: compared case-folded, a link to a name that differs only in case on a case-sensitive volume
    /// would pass.
    private static func noLink(from root: String, through relative: String) -> Bool {
        var path = root
        for part in relative.split(separator: "/") {
            path += "/" + part
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT != S_IFLNK else { return false }
        }
        return true
    }

    /// Folders the AI tools' catalog reports or cleans; `AIStorage` owns them.
    private static func aiClaimed(home: URL) -> [String] {
        let paths = AITool.catalog.flatMap { $0.footprint + $0.cleanable.flatMap(\.paths) } + AITool.sharedCaches.flatMap(\.paths)
        return paths.map { PathKey.fold(PathGuard.realPath($0.url(home: home)) ?? $0.url(home: home).path(percentEncoded: false)) }
    }
}
