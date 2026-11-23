import Foundation

/// The expanded scan's walk of the home folder for build outputs outside the usual places, within a time and item budget
/// and no depth limit.
/// - Important: It never enters what is personal or not this disk's to walk: `~/Library` (mail, photos, app data; the
///   usual scan reads its caches), the Trash, Desktop, Documents and Downloads (macOS asks the person for each), the
///   media folders, app and package bundles, links, other volumes and company security software. Cloud-synced folders
///   live inside those (`~/Library/Mobile Documents`, `~/Library/CloudStorage`, Desktop and Documents), where listing
///   one can start downloads; asking each folder whether it is synced cost a call to the sync service per folder
///   (2026-11-23: 770 folders a second with it). What it skipped is reported, and so is a walk the budget cut short.
enum ProjectDiscovery {
    /// Measured on a home with 190,000 folders to walk (2026-11-23): 56 s for all of it; 20 s reached 71,000 and found
    /// none of its 8 build caches.
    struct Budget: Sendable {
        var time: Duration = .seconds(90)
        var items = 1_000_000
    }

    /// A folder git ignores at the top of what it reports, whose name a project's own tool makes again.
    struct Artifact: Sendable, Equatable {
        let project: URL
        let folder: URL
    }

    struct Result: Sendable, Equatable {
        /// Folders shaped like an Xcode build cache: an `info.plist` naming a workspace, and `Build` or `SourcePackages`.
        var derivedData: [URL] = []
        var artifacts: [Artifact] = []
        /// `node_modules` folders beside a `package.json`, links included (their judge refuses them).
        var nodeModules: [URL] = []
        /// Kinds of places it did not walk, for the report.
        var skipped: [String] = []
        /// The budget ran out first: what was not reached is unknown, not empty.
        var partial = false
        var visited = 0
    }

    /// Top-level folders of the home never entered, with the report's words.
    static let excluded: [(name: String, reason: String)] = [
        ("Library", "~/Library(일반 검사가 캐시를 봄 · iCloud·클라우드 저장소 포함)"), (".Trash", "휴지통"),
        ("Desktop", "데스크톱(권한 창)"), ("Documents", "문서(권한 창)"), ("Downloads", "다운로드(권한 창)"),
        ("Pictures", "사진"), ("Music", "음악"), ("Movies", "동영상"),
    ]

    /// Folders whose insides are another tool's store, never a project: walking them costs much and finds nothing. A build
    /// cache holding `SourcePackages` is told one level up, before the walk would enter it.
    static let opaque: Set<String> = [".git", "node_modules", "SourcePackages", ".build", ".swiftpm", "Pods"]

    /// Build outputs by name, and the files at the project root (or beside the output) that say which tool makes them.
    /// Anything else git ignores is left alone: `.terraform` keeps the chosen workspace, `.idea` a person's settings.
    static let outputs: [String: [String]] = {
        let gradle = ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"]
        let python = ["pyproject.toml", "setup.py", "setup.cfg"]
        return ["build": gradle, ".gradle": gradle, ".cxx": gradle, "target": ["Cargo.toml", "pom.xml"], ".build": ["Package.swift"],
                ".dart_tool": ["pubspec.yaml"], ".next": ["package.json"], ".turbo": ["turbo.json"], "__pycache__": python,
                ".pytest_cache": python, ".mypy_cache": python, ".tox": ["tox.ini"], "Pods": ["Podfile"]]
    }()

    /// A folder's path folded, without the "/" a listed folder ends in.
    static func key(_ url: URL) -> String {
        let path = PathKey.fold(url.path(percentEncoded: false))
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// Whether a marker for `name` sits in the project root or beside the output.
    static func hasMarker(_ name: String, project: URL, folder: URL) -> Bool {
        guard let markers = outputs[name] else { return false }
        return [project, folder.deletingLastPathComponent()].contains { place in
            markers.contains { FileManager.default.fileExists(atPath: place.appending(path: $0).path(percentEncoded: false)) }
        }
    }

    static func walk(home: URL, budget: Budget = Budget()) -> Result {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: budget.time)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .volumeIdentifierKey]
        let homeVolume = (try? home.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        var result = Result(skipped: excluded.map(\.reason))
        var counts: [String: Int] = [:]
        let skipNames = Set(excluded.map { PathKey.fold($0.name) })
        var stack: [URL] = []
        var gitRoots: [URL] = []
        // Folders only: files are never what it looks for. A link is counted and never followed.
        func push(_ children: [URL]) {
            for child in children {
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true { counts["링크", default: 0] += 1 } else if values?.isDirectory == true { stack.append(child) }
            }
        }
        // Hidden folders at the top of the home are tools' own stores (`~/.cache`, `~/.npm`), which the usual scan reads.
        push((try? FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: keys))?
            .filter { !skipNames.contains(PathKey.fold($0.lastPathComponent)) && !$0.lastPathComponent.hasPrefix(".") } ?? [])

        while let folder = stack.popLast() {
            result.visited += 1
            if result.visited > budget.items || clock.now >= deadline {
                result.partial = true
                break
            }
            guard let values = try? folder.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isPackage == true { counts["앱·패키지 묶음", default: 0] += 1; continue }
            if let homeVolume, (values.volumeIdentifier as? NSObject).map({ !$0.isEqual(homeVolume) }) ?? true {
                counts["다른 볼륨", default: 0] += 1
                continue
            }
            // Its own name only: every folder above it was checked when the walk reached it.
            if CleanupRoots.isManagedSoftware(folder.lastPathComponent) { counts["보안 소프트웨어", default: 0] += 1; continue }
            if opaque.contains(folder.lastPathComponent) { continue }
            guard let children = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else {
                counts["읽지 못한 폴더", default: 0] += 1
                continue
            }
            let names = Set(children.map(\.lastPathComponent))
            // A worktree has a `.git` file, a clone a `.git` folder.
            if names.contains(".git") { gitRoots.append(folder) }
            if names.contains("node_modules"), names.contains("package.json") { result.nodeModules.append(folder.appending(path: "node_modules")) }
            if names.contains("info.plist"), names.contains("Build") || names.contains("SourcePackages"),
               XcodeCacheScanner.workspacePath(of: folder) != nil {
                result.derivedData.append(folder)
                continue
            }
            push(children)
        }
        // What git ignores in each project, while time is left; a project it cannot list offers nothing.
        for root in gitRoots {
            let left = deadline - clock.now
            guard left > .zero, let ignored = Git.ignoredFolders(root, timeout: min(left, .seconds(30))) else {
                counts["git 목록을 못 읽은 프로젝트", default: 0] += 1
                if clock.now >= deadline { result.partial = true }
                continue
            }
            for relative in ignored {
                let folder = root.appending(path: relative)
                guard hasMarker(folder.lastPathComponent, project: root, folder: folder) else { continue }
                // A build cache inside is a row of its own; the folder holding it is not one.
                let path = key(folder)
                if result.derivedData.contains(where: { (key($0) + "/").hasPrefix(path + "/") }) { continue }
                result.artifacts.append(Artifact(project: root, folder: folder))
            }
        }
        result.skipped += counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)곳" }
        return result
    }
}

/// Rows for the build outputs the walk found outside the usual places, one per folder. Each is judged by its grant, the
/// same function the executor asks again before deleting it. Never in the shallow clean-up: a granted folder is the
/// dashboard's only (`isShallow`).
enum ProjectOutputScanner {
    typealias Judge = @Sendable (TargetGrant, TargetGrant.Inputs) -> (refusal: String?, facts: TreeFacts)

    /// The refusal of a folder reached after the expanded scan's deadline; the coordinator counts these rather than list them.
    static let outOfTime = "시간이 다 돼 판정하지 못했습니다"

    /// Each cache is judged as the usual scan would first. Only when an alarm kept it, and the caller allows re-proving,
    /// it is judged again with the package proof re-proven. One that passes the first way is ticked to begin with in the
    /// dashboard; one only the re-proof cleared, and every one while the borrower memory does not read, a person picks.
    static func rows(_ found: [URL], context: ScanContext, lending: XcodeCacheScanner.Lending, reprove: Bool,
                     judge: Judge = TargetGrant.evaluate) -> [CleanupCandidate] {
        found.compactMap { folder in
            let grant = TargetGrant(kind: .derivedData, path: folder)
            let inputs = TargetGrant.Inputs(now: context.now, ages: context.ages, open: context.openFiles,
                                            borrowers: Array(lending.outside(folder, row: [folder])), reprove: false, deadline: context.deadline)
            var judged = judge(grant, inputs)
            var reproved = false
            if reprove, judged.facts.alarm != nil {
                var again = inputs
                again.reprove = reprove
                judged = judge(grant, again)
                reproved = true
            }
            guard judged.facts.bytes >= ScanSupport.minimumBytes || !judged.facts.isComplete else { return nil }
            var evidence = Evidence(verified: true, inUse: false, regenerable: true)
            evidence.protectedReason = judged.refusal
            let workspace = XcodeCacheScanner.workspacePath(of: folder).map { URL(fileURLWithPath: $0) }
            let project = workspace?.deletingLastPathComponent().lastPathComponent ?? folder.lastPathComponent
            let path = folder.path(percentEncoded: false)
            var row = CleanupCandidate(
                id: "project.derivedData." + PathKey.fold(path),
                name: "\(project) · \(workspace?.deletingPathExtension().lastPathComponent ?? folder.lastPathComponent) (프로젝트 안 Xcode 캐시)",
                detail: ScanSupport.display(path, home: context.home) + " · 표준 위치 밖 · " + ScanSupport.ago(judged.facts.newest, now: context.now),
                symbol: "hammer", bytes: judged.facts.bytes, evidence: evidence, lowerBound: !judged.facts.isComplete,
                targets: [CleanupTarget(path: folder, root: folder.deletingLastPathComponent(), identity: FileIdentity.of(path),
                                        action: .removeItem, grant: grant)],
                lastUsed: judged.facts.newest)
            row.manualOnly = reproved || lending.memoryCorrupt
            row.reproved = reproved
            // The judge read open files under the workspace's folder too; the executor asks it again from a fresh snapshot.
            if let workspace { row.guards.watchPaths = [workspace.deletingLastPathComponent()] }
            return row
        }
    }

    /// Rows for the build outputs git ignores in a project, one per folder, judged by their grant like the caches above.
    static func artifactRows(_ found: [ProjectDiscovery.Artifact], context: ScanContext, judge: Judge = TargetGrant.evaluate) -> [CleanupCandidate] {
        found.compactMap { artifact in
            let grant = TargetGrant(kind: .projectArtifact(project: artifact.project), path: artifact.folder)
            let judged = judge(grant, .init(now: context.now, ages: context.ages, open: context.openFiles, borrowers: [], reprove: false,
                                            home: context.home, deadline: context.deadline))
            guard judged.facts.bytes >= ScanSupport.minimumBytes || !judged.facts.isComplete else { return nil }
            var evidence = Evidence(verified: true, inUse: false, regenerable: true)
            evidence.protectedReason = judged.refusal
            evidence.downloadCost = true
            evidence.costReason = "다음 빌드에서 다시 만들거나 내려받습니다."
            let path = artifact.folder.path(percentEncoded: false)
            var row = CleanupCandidate(
                id: "project.artifact." + ProjectDiscovery.key(artifact.folder),
                name: "\(artifact.project.lastPathComponent) · \(artifact.folder.lastPathComponent)",
                detail: ScanSupport.display(path, home: context.home) + " · git이 무시하는 빌드 산출물 · " + ScanSupport.ago(judged.facts.newest, now: context.now),
                symbol: "shippingbox", bytes: judged.facts.bytes, evidence: evidence, lowerBound: !judged.facts.isComplete,
                targets: [CleanupTarget(path: artifact.folder, root: artifact.folder.deletingLastPathComponent(), identity: FileIdentity.of(path),
                                        action: .removeItem, grant: grant)],
                lastUsed: judged.facts.newest)
            row.manualOnly = true
            return row
        }
    }

    /// Rows for `node_modules` of projects left alone long, one per folder, judged by their grant.
    static func nodeModulesRows(_ found: [URL], context: ScanContext, judge: Judge = TargetGrant.evaluate) -> [CleanupCandidate] {
        found.compactMap { folder in
            let grant = TargetGrant(kind: .nodeModules, path: folder)
            let judged = judge(grant, .init(now: context.now, ages: context.ages, open: context.openFiles, borrowers: [], reprove: false,
                                            home: context.home, deadline: context.deadline))
            guard judged.facts.bytes >= ScanSupport.minimumBytes || !judged.facts.isComplete else { return nil }
            var evidence = Evidence(verified: true, inUse: false, regenerable: true)
            evidence.protectedReason = judged.refusal
            evidence.downloadCost = true
            evidence.costReason = "npm install 로 다시 받습니다 · 직접 고친 내용은 사라집니다."
            let path = folder.path(percentEncoded: false)
            var row = CleanupCandidate(
                id: "project.nodeModules." + ProjectDiscovery.key(folder),
                name: "\(folder.deletingLastPathComponent().lastPathComponent) · node_modules",
                detail: ScanSupport.display(path, home: context.home) + " · 프로젝트 마지막 변경 " + ScanSupport.ago(judged.facts.newest, now: context.now),
                symbol: "shippingbox", bytes: judged.facts.bytes, evidence: evidence, lowerBound: !judged.facts.isComplete,
                targets: [CleanupTarget(path: folder, root: folder.deletingLastPathComponent(), identity: FileIdentity.of(path),
                                        action: .removeItem, grant: grant)],
                lastUsed: judged.facts.newest)
            row.manualOnly = true
            row.guards.watchPaths = [folder.deletingLastPathComponent()]
            return row
        }
    }
}

/// A project's installed packages, gone only when the project has been left alone long and nothing about them is the
/// person's own work: not a workspace member (its root installs for it), no hand-patched package, no recent install.
enum NodeModules {
    /// Written by npm, Yarn and pnpm on every install.
    static let installRecords = [".package-lock.json", ".yarn-integrity", ".modules.yaml"]
    static let patchFolders = ["patches", ".yarn/patches", ".patches"]

    /// The project and the folders above it, up to the repository root (a folder holding `.git`) or the home.
    static func chain(_ project: URL, home: URL?) -> [URL] {
        guard let home else { return [project] }
        let top = ProjectDiscovery.key(home)
        var chain: [URL] = []
        var folder = project
        while ProjectDiscovery.key(folder).hasPrefix(top + "/") {
            chain.append(folder)
            if FileManager.default.fileExists(atPath: folder.appending(path: ".git").path(percentEncoded: false)) { break }
            folder = folder.deletingLastPathComponent()
        }
        return chain.isEmpty ? [project] : chain
    }

    /// A folder's `package.json`: none, one that does not read as a JSON object, or its object.
    enum Manifest { case missing, unreadable, object([String: Any]) }
    static func manifest(_ folder: URL) -> Manifest {
        let url = folder.appending(path: "package.json")
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return .missing }
        guard let data = try? Data(contentsOf: url), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .unreadable }
        return .object(object)
    }

    static func refusal(_ folder: URL, _ inputs: TargetGrant.Inputs) -> (String?, TreeFacts) {
        let deadline = inputs.deadline
        var facts = TreeWalk.inspect(folder, budget: .seconds(60), until: deadline,
                                     alarm: { CacheRules.isAlarmName($0, isFolder: $1, reprove: false, until: deadline) })
        let project = folder.deletingLastPathComponent()
        var info = stat()
        if lstat(folder.path(percentEncoded: false), &info) != 0 || info.st_mode & S_IFMT == S_IFLNK { return ("링크이거나 읽을 수 없습니다", facts) }
        guard case .object = manifest(project) else { return ("package.json 을 읽지 못했습니다", facts) }
        let has = { (folder: URL, name: String) in FileManager.default.fileExists(atPath: folder.appending(path: name).path(percentEncoded: false)) }
        for (index, place) in chain(project, home: inputs.home).enumerated() {
            if patchFolders.contains(where: { has(place, $0) }) { return ("직접 고친 패키지 기록이 있습니다", facts) }
            let pnpm = (try? String(contentsOf: place.appending(path: "pnpm-workspace.yaml"), encoding: .utf8)) ?? ""
            if pnpm.contains("patchedDependencies") { return ("직접 고친 패키지 기록이 있습니다", facts) }
            switch manifest(place) {
            case .unreadable: return ("package.json 을 읽지 못했습니다", facts)
            case .object(let object):
                if object["patchedDependencies"] != nil || (object["pnpm"] as? [String: Any])?["patchedDependencies"] != nil {
                    return ("직접 고친 패키지 기록이 있습니다", facts)
                }
                if index > 0, object["workspaces"] != nil { return ("워크스페이스 멤버라 루트에서 함께 설치합니다", facts) }
            case .missing: break
            }
            if index > 0, has(place, "pnpm-workspace.yaml") || has(place, "lerna.json") { return ("워크스페이스 멤버라 루트에서 함께 설치합니다", facts) }
        }
        if let alarm = facts.alarm { return (CacheRules.alarmReason(alarm), facts) }
        guard facts.isComplete, let activity = lastActivity(project, until: deadline) else { return ("다 훑지 못해 마지막 사용 시각을 모릅니다", facts) }
        facts.newest = activity
        if inputs.now.timeIntervalSince(activity) < inputs.ages.seconds(.nodeModules) { return ("최근에 쓰거나 설치했습니다.", facts) }
        guard let open = inputs.open else { return ("열린 파일을 확인하지 못했습니다", facts) }
        if open.anyOpen(under: folder.path(percentEncoded: false)) || open.anyOpen(under: project.path(percentEncoded: false)) {
            return ("지금 쓰는 파일이 있습니다", facts)
        }
        return (nil, facts)
    }

    /// The latest change to the project outside `node_modules`, to `node_modules`' top entries (an install moves them;
    /// package files themselves carry the dates their authors packed) and to the install records; nil when a part cannot
    /// be read in time, or `until` has passed.
    static func lastActivity(_ project: URL, until: ContinuousClock.Instant? = nil) -> Date? {
        if let until, ContinuousClock.now >= until { return nil }
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey]
        var newest = Date.distantPast
        guard let entries = try? FileManager.default.contentsOfDirectory(at: project, includingPropertiesForKeys: Array(keys)) else { return nil }
        for entry in entries where entry.lastPathComponent != ".git" {
            guard let values = try? entry.resourceValues(forKeys: keys), let modified = values.contentModificationDate else { return nil }
            if entry.lastPathComponent == "node_modules" {
                guard let top = try? FileManager.default.contentsOfDirectory(at: entry, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
                for item in top {
                    guard let date = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return nil }
                    newest = max(newest, date)
                }
                newest = max(newest, modified)
            } else if values.isDirectory == true, values.isSymbolicLink != true {
                let facts = TreeWalk.inspect(entry, budget: .seconds(30), until: until)
                guard facts.isComplete else { return nil }
                newest = max(newest, facts.newest ?? modified)
            } else {
                newest = max(newest, modified)
            }
        }
        return newest
    }
}

/// The few read-only git questions the expanded scan asks about a project. No locks taken, no hooks, no filesystem
/// monitor started, nothing fetched.
enum Git {
    static func run(_ root: URL, _ arguments: [String], timeout: Duration) -> Command.Output? {
        guard DeveloperTools.available else { return nil }
        return Command.run("/usr/bin/git", ["-C", root.path(percentEncoded: false), "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null"]
                           + arguments, timeout: timeout, environment: ["GIT_OPTIONAL_LOCKS": "0", "GIT_NO_LAZY_FETCH": "1"], maxBytes: 4_000_000)
    }

    /// Folders git ignores whole, relative to the root, each ending in "/"; nil when git fails, times out or says too much.
    static func ignoredFolders(_ root: URL, timeout: Duration) -> [String]? {
        guard let output = run(root, ["ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--directory"], timeout: timeout),
              output.status == 0 else { return nil }
        return output.stdout.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }.filter { $0.hasSuffix("/") }
    }

    /// Whether git ignores `folder` whole; nil when it cannot tell. A folder with any file git tracks inside is not
    /// ignored: `check-ignore` consults the index (measured 2026-11-23: a tracked file deep inside turns 0 into 1).
    /// nil too once `until` has passed.
    static func isIgnored(_ folder: URL, project: URL, until: ContinuousClock.Instant? = nil) -> Bool? {
        let relative = String(folder.path(percentEncoded: false).dropFirst(project.path(percentEncoded: false).count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let timeout = ScanSupport.budget(.seconds(30), until: until)
        guard !relative.isEmpty, timeout > .zero, let check = run(project, ["check-ignore", "-q", "--", relative], timeout: timeout) else { return nil }
        // 0 ignored, 1 not ignored, anything else an error.
        guard check.status == 0 || check.status == 1 else { return nil }
        return check.status == 0
    }
}
