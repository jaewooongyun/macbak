import Foundation

/// App caches in `~/Library/Caches` (one row per app, its contents offered, the folder kept) and old logs in
/// `~/Library/Logs` (one row, only files untouched for the log age, 30 days by default).
/// - Important: Folders another scanner owns (AI tools, xcode-build-server) are left out here so nothing is offered twice.
///   The cache rules run on every row: their "keep" protects it whatever else is true, and their "offer" makes it a
///   choice. Their "don't know" changes nothing here, because the user's three-day rule already covers Library/Caches.
enum AppCacheScanner {

    /// Never offered here: xcode-build-server belongs to the Xcode row.
    /// - Note: The SwiftPM cache used to be kept; the user moved it to "a choice" on 2026-11-03, which the rules say.
    static let excludedNames: Set<String> = ["xcode-build-server"]
    /// Caches that hold downloads, which cost time and data to fetch again: always a person's choice.
    static let downloadCaches: Set<String> = [
        "homebrew", "pip", "pypoetry", "yarn", "pnpm", "node-gyp", "cypress", "cocoapods", "org.carthage.carthagekit", "jetbrains",
    ]

    static func scan(_ context: ScanContext) -> [CleanupCandidate] {
        appCaches(context) + [oldLogs(context)].compactMap(\.self)
    }

    private static func appCaches(_ context: ScanContext) -> [CleanupCandidate] {
        guard let root = ScanSupport.resolved(context.home, "Library/Caches"), let items = ScanSupport.children(of: root) else { return [] }
        let claimed = claimedPaths(home: context.home)
        var candidates: [CleanupCandidate] = []
        for item in items {
            let name = item.lastPathComponent
            let path = PathKey.fold(item.path(percentEncoded: false))
            guard !name.hasPrefix("."), !name.hasPrefix("com.apple."), !excludedNames.contains(name), !CleanupRoots.isManagedSoftware(name),
                  !claimed.contains(where: { path == $0 || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/") }) else { continue }
            let before = FileIdentity.of(item.path(percentEncoded: false))
            let facts = TreeWalk.inspect(item, budget: .seconds(30), alarm: CacheRules.isAlarmName, notice: CacheRules.blocksShallow)
            guard facts.bytes >= ScanSupport.minimumBytes || !facts.isComplete else { continue }

            // The contents go; the folder stays, since some apps expect it to exist.
            var targets: [CleanupTarget] = []
            var complete = facts.isComplete
            if (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                if let inside = ScanSupport.children(of: item) {
                    targets = ScanSupport.removals(of: inside, root: root)
                } else {
                    complete = false
                }
            } else {
                targets = [ScanSupport.removal(item, root: root)]
            }
            // The targets are listed after the walk; an entry added or removed in between would be one the walk never
            // judged. The folder's own identity moves with its direct entries, so a change means "not verified".
            if FileIdentity.of(item.path(percentEncoded: false)) != before { complete = false }

            let folded = PathKey.fold(name)
            var evidence = Evidence(verified: complete && facts.newest != nil ? true : nil, inUse: ScanSupport.isOpen(context, [item]), regenerable: true)
            if context.runningBundleIDs.contains(where: { PathKey.fold($0) == folded }) { evidence.inUse = true }
            // The user's rule (Settings, three days by default): a cache untouched that long goes; it is rebuilt when next needed.
            if let idle = facts.idle(at: context.now), idle < context.ages.seconds(.appCache) { evidence.recentlyUsed = true }
            if downloadCaches.contains(folded) { evidence.downloadCost = true }
            let installed = context.installedBundleIDs.contains(name)

            let relative = "Library/Caches/" + name
            let listing = CacheRules.listing(home: context.home, relative: relative)
            let rules = CacheRules.tier(path: relative, inside: listing.inside, beside: listing.beside, home: context.home)
            switch rules.tier {
            case .keep: evidence.protectedReason = CacheRules.protectedReason(rules)
            case .offer:
                evidence.downloadCost = true
                evidence.costReason = CacheRules.costReason(rules)
            case .precheck, .model: break
            }
            if rules.tier != .keep, let alarm = facts.alarm { evidence.protectedReason = CacheRules.alarmReason(alarm) }
            // The rules cannot tell what it is, so only the person's 3-day rule would tick it: the on-device model looks
            // first and may object. Rows that would not be ticked anyway are not sent.
            let veto = rules.tier == .model && evaluate(evidence).status == .ready
                && CacheRules.modelMayOffer(path: relative, inside: listing.inside)
            if veto { evidence.awaitingModel = true }
            var detail = [installed ? "앱 캐시" : "주인을 확인하지 못한 캐시", "~/Library/Caches/\(name)", ScanSupport.ago(facts.newest, now: context.now)]

            var candidate = CleanupCandidate(
                id: "caches." + folded, name: name, detail: detail.joined(separator: " · "),
                symbol: "archivebox", bytes: facts.bytes, evidence: evidence, lowerBound: !complete, targets: targets, lastUsed: facts.newest,
                guards: CleanupGuards(bundleIDs: name.contains(".") ? [name] : []))
            candidate.toolCommand = rules.devRow?.command.isEmpty == false ? rules.devRow?.command : nil
            // Apple promises an app's Caches can be re-created, and the person's rule deletes them after 3 idle days. An
            // app cache goes to the shallow clean-up, which deletes without a click, only when the rules recognise what
            // is in it and nothing inside looks like a document: what only the 3-day rule ticks (the model can veto it,
            // never vouch for it) stays a dashboard tick.
            candidate.trusted = rules.tier != .model && facts.noticed == nil
            if veto {
                candidate.exploreInput = ExploreInput(url: item, relative: relative, inside: listing.inside, beside: listing.beside, role: .veto)
            }
            candidates.append(candidate)
        }
        return candidates
    }

    /// One row for every log file untouched for the log age (Settings, 30 days by default). A folder that cannot be read
    /// in full is left out entirely, and files a process has open are skipped, so each listed file stands on its own evidence.
    private static func oldLogs(_ context: ScanContext) -> CleanupCandidate? {
        guard let root = ScanSupport.resolved(context.home, "Library/Logs"), let items = ScanSupport.children(of: root) else { return nil }
        let cutoff = context.now.addingTimeInterval(-context.ages.seconds(.logs))
        var targets: [CleanupTarget] = []
        var skipped = 0
        var bytes: Int64 = 0
        for item in items where !CleanupRoots.isManagedSoftware(item.lastPathComponent) {
            // The same deep checks as every other shallow row: a key, wallet, disk image or document anywhere in a log
            // folder keeps the whole folder out, old files included.
            let facts = TreeWalk.inspect(item, budget: .seconds(20), olderThan: cutoff, collect: true, alarm: CacheRules.isAlarmName,
                                         notice: CacheRules.blocksShallow)
            guard facts.isComplete, facts.alarm == nil, facts.noticed == nil else { skipped += 1; continue }
            let files = facts.listed.filter { context.openFiles?.anyOpen(under: $0.path) == false }
            guard !files.isEmpty else { continue }
            bytes += files.reduce(0) { $0 + $1.bytes }
            targets.append(CleanupTarget(path: item, root: root, identity: FileIdentity.of(item.path(percentEncoded: false)), action: .removeFiles(files)))
        }
        guard bytes >= ScanSupport.minimumBytes else { return nil }
        let count = targets.reduce(0) { total, target in
            if case .removeFiles(let files) = target.action { return total + files.count }
            return total
        }
        var detail = "~/Library/Logs · \(context.ages.logs)일 넘은 파일 \(count)개"
        if skipped > 0 { detail += " · 읽지 못했거나 지킬 파일이 있는 폴더 \(skipped)개는 뺌" }
        let evidence = Evidence(verified: true, inUse: context.openFiles == nil ? nil : false, regenerable: true)
        var row = CleanupCandidate(id: "logs.old", name: "\(context.ages.logs)일 넘은 로그", detail: detail, symbol: "doc.text", bytes: bytes,
                                   evidence: evidence, targets: targets, lastUsed: cutoff)
        row.trusted = true
        return row
    }

    /// Every folder the AI catalog reports or cleans, folded for comparison.
    private static func claimedPaths(home: URL) -> [String] {
        let paths = AITool.catalog.flatMap { $0.footprint + $0.cleanable.flatMap(\.paths) } + AITool.sharedCaches.flatMap(\.paths)
        return paths.map { PathKey.fold(PathGuard.realPath($0.url(home: home)) ?? $0.url(home: home).path(percentEncoded: false)) }
    }
}
