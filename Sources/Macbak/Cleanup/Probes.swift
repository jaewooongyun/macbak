import Darwin
import Foundation
import os

// The facts a clean-up judgment is made of. Each probe reports what it could not read instead of guessing, so a failure
// can only ever keep something, never clear it for deletion.

/// Whether Xcode or the command-line tools are installed. `/usr/bin/xcrun` and `/usr/bin/git` are stubs that, on a Mac
/// without them, open a dialog offering to install the tools; `xcode-select -p` only reports. Asked once per launch.
enum DeveloperTools {
    static let available: Bool = {
        guard let output = Command.run("/usr/bin/xcode-select", ["-p"], timeout: .seconds(5)), output.status == 0 else { return false }
        let path = String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return !path.isEmpty && FileManager.default.fileExists(atPath: path)
    }()
}

/// Runs a command and returns its output, or nil when it could not start or ran past `timeout`.
enum Command {
    struct Output: Sendable {
        let status: Int32
        let stdout: Data
    }

    /// - Important: Returns by the deadline whatever the command does. Waiting for its output or its exit without one hung
    ///   the caller for good when a process ignored SIGTERM, was stuck in the kernel (`lsof` on a dead network volume), or
    ///   left a child holding the output pipe; a run waiting on `lsof` then stayed "정리하는 중" forever. After the deadline
    ///   the process gets SIGTERM, then SIGKILL two seconds later, and the reading thread is abandoned if still blocked.
    /// - Parameters:
    ///   - environment: added to the inherited environment; nil runs with it unchanged.
    ///   - maxBytes: output past this ends the process and answers nil, so a huge listing cannot fill memory.
    static func run(_ executable: String, _ arguments: [String], timeout: Duration, environment: [String: String]? = nil,
                    maxBytes: Int? = nil) -> Output? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 } }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }

        // Read on another thread, all the way to the end so a large output never fills the pipe and stalls the process.
        // A thread of its own, not a GCD worker: callers block a pool thread each while they wait here, and once they
        // fill the pool no worker comes to read, so every call waits out its timeout (2026-11-23: 14 of 14 pool
        // threads waiting on `read`, no reader running).
        let output = OSAllocatedUnfairLock<Data?>(initialState: nil)
        let read = DispatchSemaphore(value: 0)
        Thread {
            let handle = pipe.fileHandleForReading
            var data = Data()
            if let maxBytes {
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    data.append(chunk)
                    // Too much: stop the command; nil below, whatever it printed.
                    if data.count > maxBytes {
                        process.terminate()
                        output.withLock { $0 = nil }
                        read.signal()
                        return
                    }
                }
            } else {
                data = handle.readDataToEndOfFile()
            }
            let whole = data
            output.withLock { $0 = whole }
            read.signal()
        }.start()
        let deadline = DispatchTime.now() + timeout.seconds
        guard exited.wait(timeout: deadline) == .success else {
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut { kill(process.processIdentifier, SIGKILL) }
            return nil
        }
        // Exited, but a child it left may still hold the pipe: the output is only whole once it closes.
        guard read.wait(timeout: max(deadline, .now() + 1)) == .success, let data = output.withLock({ $0 }) else { return nil }
        return Output(status: process.terminationStatus, stdout: data)
    }
}

extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

/// Paths that running processes have open, from one `lsof` run.
/// - Important: `capture()` returns nil when `lsof` fails, times out or prints implausibly little, and nil means nothing
///   may count as unused. A missing snapshot must never read as "nothing is open".
struct OpenFiles: Sendable {
    /// A full snapshot is tens of thousands of lines; a few hundred means `lsof` saw almost nothing.
    static let minimumLines = 1_000

    /// Case-folded and sorted, so a prefix lookup is a binary search.
    private let paths: [String]

    static func capture() -> OpenFiles? {
        Command.run("/usr/sbin/lsof", ["-n", "-Fpcn"], timeout: .seconds(15)).flatMap { parse($0) }
    }

    /// `-Fpcn` prints a `p<pid>` and a `c<command>` line per process and an `n<name>` line per open file; names that are
    /// not paths are skipped, and so are Macbak's own. Its scans hold folders open while walking them, which made the
    /// build caches it was reading look in use (2026-11-04). Any process named Macbak counts as its own, so a second
    /// copy (a measurement copy, `--scan-report`) does not mark the app's caches in use either.
    static func parse(_ output: Command.Output, ownPID: Int32 = getpid()) -> OpenFiles? {
        guard output.status == 0 else { return nil }
        let lines = String(decoding: output.stdout, as: UTF8.self).split(separator: "\n")
        guard lines.count >= minimumLines else { return nil }
        var own = false
        var paths: [String] = []
        for line in lines {
            switch line.first {
            case "p": own = Int32(line.dropFirst()) == ownPID
            case "c": if line.dropFirst() == "Macbak" { own = true }
            case "n": if !own, line.hasPrefix("n/") { paths.append(PathKey.fold(String(line.dropFirst()))) }
            default: break
            }
        }
        return OpenFiles(paths: paths.sorted())
    }

    /// Whether a process has `root` itself, or anything below it, open. `/a/b-old` is not below `/a/b`.
    /// - Note: A trailing `/` is ignored: `URL.path(percentEncoded:)` leaves one on folder URLs, while `lsof` never does.
    func anyOpen(under root: String) -> Bool {
        var key = PathKey.fold(root)
        while key.count > 1, key.hasSuffix("/") { key.removeLast() }
        if contains(key) { return true }
        let prefix = key.hasSuffix("/") ? key : key + "/"
        let index = lowerBound(prefix)
        return index < paths.count && paths[index].hasPrefix(prefix)
    }

    private func contains(_ key: String) -> Bool {
        let index = lowerBound(key)
        return index < paths.count && paths[index] == key
    }

    private func lowerBound(_ key: String) -> Int {
        var low = 0, high = paths.count
        while low < high {
            let mid = (low + high) / 2
            if paths[mid] < key { low = mid + 1 } else { high = mid }
        }
        return low
    }
}

/// SwiftPM's package checkouts in a build cache (`…/SourcePackages/checkouts/<package>/`) are git working trees. An item
/// there that is exactly what the package's fetched history holds is the package's own; the next build fetches it again.
/// - Important: Fails closed. All must hold, or the answer is false: the checkout's HEAD is contained in a remote-tracking
///   ref and no local branch or stash holds a commit the remote-tracking refs lack (a commit made only here would be
///   lost with the checkout), and every regular file on disk at the path is a blob HEAD has there
///   with the same bytes (a folder document such as a `.numbers` bundle is compared file by file). Links,
///   submodules, git failing or taking over ten seconds all answer false.
/// - Note: Nothing is written and the index is never read, so git does not refresh it (a write that would make the cache
///   look used); `--no-filters` runs no `.gitattributes` filter program.
enum PackageCheckout {
    /// - Parameter reprove: when the proof fails because every object folder the checkout borrows through
    ///   `.git/objects/info/alternates` is gone (the build cache that lent them was deleted), prove it again against the
    ///   same packages' object folders inside this checkout's own build cache. Only the expanded scan asks for it; it
    ///   costs git calls the periodic scan must not add.
    /// - Parameter until: every git call and the file listing end by then; past it the answer is false.
    static func isPristine(_ url: URL, reprove: Bool = false, until: ContinuousClock.Instant? = nil) -> Bool {
        if let until, ContinuousClock.now >= until { return false }
        let path = url.path(percentEncoded: false)
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        // Without developer tools (Xcode removed, its build caches left behind) git would open an install dialog.
        guard let at = parts.indices.dropFirst().first(where: { parts[$0].lowercased() == "checkouts" && parts[$0 - 1].lowercased() == "sourcepackages" }),
              at + 2 < parts.count, DeveloperTools.available else { return false }
        let root = parts[...(at + 1)].joined(separator: "/")
        let inside = parts[(at + 2)...].joined(separator: "/")
        if proves(url, root: root, inside: inside, environment: nil, until: until) { return true }
        guard reprove, let objects = sameCacheObjects(checkout: root, cache: parts[..<(at - 1)].joined(separator: "/")) else { return false }
        // No locks, no lazy fetch: the proof only reads.
        return proves(url, root: root, inside: inside, environment: ["GIT_ALTERNATE_OBJECT_DIRECTORIES": objects.joined(separator: ":"),
                                                                     "GIT_OPTIONAL_LOCKS": "0", "GIT_NO_LAZY_FETCH": "1"], until: until)
    }

    /// The object folders to borrow instead, or nil unless all hold: every folder the checkout's alternates name is gone
    /// (one still there means the failure is something else, and nothing outside is followed); each named a package's
    /// `SourcePackages/repositories/<name>/objects`; the same path exists in `cache`, is no link, and borrows from nowhere
    /// itself (its own non-empty alternates could lead out of the cache).
    static func sameCacheObjects(checkout: String, cache: String) -> [String]? {
        let objects = checkout + "/.git/objects"
        guard let text = try? String(contentsOfFile: objects + "/info/alternates", encoding: .utf8) else { return nil }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard !lines.isEmpty else { return nil }
        let marker = "/SourcePackages/repositories/"
        var found: [String] = []
        for line in lines {
            let named = line.hasPrefix("/") ? line : objects + "/" + line
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: named, isDirectory: &isFolder) { return nil }
            guard let range = named.range(of: marker, options: [.caseInsensitive, .backwards]) else { return nil }
            let tail = String(named[range.upperBound...])
            guard !tail.isEmpty, !tail.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { return nil }
            let replacement = cache + "/SourcePackages/repositories/" + tail
            // No link anywhere below the cache: the folder resolves to the cache's own resolved path plus the same tail.
            guard let realCache = PathGuard.realPath(URL(fileURLWithPath: cache)),
                  PathGuard.realPath(URL(fileURLWithPath: replacement)) == realCache + "/SourcePackages/repositories/" + tail,
                  FileManager.default.fileExists(atPath: replacement, isDirectory: &isFolder), isFolder.boolValue else { return nil }
            let own = (try? String(contentsOfFile: replacement + "/info/alternates", encoding: .utf8)) ?? ""
            guard own.split(whereSeparator: \.isNewline).allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty || $0.hasPrefix("#") })
            else { return nil }
            found.append(replacement)
        }
        return found
    }

    /// The proof itself, as described on the type.
    private static func proves(_ url: URL, root: String, inside: String, environment: [String: String]?, until: ContinuousClock.Instant?) -> Bool {
        /// The output of a command that succeeded, empty or not; nil when it failed or no time is left.
        func run(_ arguments: [String]) -> Data? {
            let timeout = ScanSupport.budget(.seconds(10), until: until)
            guard timeout > .zero,
                  let output = Command.run("/usr/bin/git", ["-C", root, "--literal-pathspecs"] + arguments, timeout: timeout,
                                           environment: environment),
                  output.status == 0 else { return nil }
            return output.stdout
        }
        func git(_ arguments: [String]) -> Data? { run(arguments).flatMap { $0.isEmpty ? nil : $0 } }
        guard git(["for-each-ref", "--contains", "HEAD", "--count=1", "--format=%(refname)", "refs/remotes"]) != nil,
              // The whole checkout goes with the cache, so no branch or stash may hold a commit the remote does not have.
              run(["rev-list", "-n", "1", "--branches", "--glob=refs/stash", "--not", "--remotes"])?.isEmpty == true,
              let tree = git(["ls-tree", "-r", "-z", "HEAD", "--", inside]) else { return false }
        // "<mode> blob <hash>\t<path>", one per regular file HEAD has at the path.
        var committed: [String: String] = [:]
        for entry in tree.split(separator: 0) {
            let line = String(decoding: entry, as: UTF8.self)
            guard let tab = line.firstIndex(of: "\t") else { return false }
            let fields = line[..<tab].split(separator: " ")
            guard fields.count == 3, fields[0] == "100644" || fields[0] == "100755", fields[1] == "blob" else { return false }
            committed[String(line[line.index(after: tab)...])] = String(fields[2])
        }
        guard let disk = regularFiles(at: url, until: until), !disk.isEmpty, disk.allSatisfy({ $0.hasPrefix(root + "/") }),
              let hashes = git(["hash-object", "--no-filters", "--"] + disk) else { return false }
        // A file HEAD does not have there finds no blob and fails; a committed file missing on disk deletes nothing.
        let lines = String(decoding: hashes, as: UTF8.self).split(separator: "\n").map(String.init)
        return lines.count == disk.count && zip(disk, lines).allSatisfy { committed[String($0.dropFirst(root.count + 1))] == $1 }
    }

    /// The item itself if it is a regular file, or every file below it if it is a folder; nil on a link or anything else,
    /// or once `until` has passed.
    private static func regularFiles(at url: URL, until: ContinuousClock.Instant?) -> [String]? {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let top = try? url.resourceValues(forKeys: Set(keys)), top.isSymbolicLink != true else { return nil }
        if top.isRegularFile == true { return [url.path(percentEncoded: false)] }
        var unreadable = false
        guard top.isDirectory == true,
              let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [],
                                                          errorHandler: { _, _ in unreadable = true; return false }) else { return nil }
        var files: [String] = []
        for case let item as URL in walker {
            if let until, ContinuousClock.now >= until { return nil }
            guard let values = try? item.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true else { return nil }
            if values.isRegularFile == true { files.append(item.path(percentEncoded: false)) } else if values.isDirectory != true { return nil }
        }
        return unreadable ? nil : files
    }
}

/// Comparable form of a path on APFS, which ignores case and Unicode normalization by default.
enum PathKey {
    static func fold(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.lowercased() }
}

/// Which file a path pointed at when it was scanned. A different identity at deletion time means the path was replaced.
/// Which item a path names, and whether it changed. Equal only when it is the same item, not modified since.
/// - Note: A folder's own modification time moves when an entry directly inside is added, removed or renamed — a new
///   result bundle, a replaced `info.plist` — but not when a file deeper down is written. It catches those without a re-walk.
struct FileIdentity: Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64

    /// The item itself, not what a symbolic link points to; nil when it cannot be read.
    static func of(_ path: String) -> FileIdentity? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino),
                            modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec))
    }
}

/// What one walk of a folder found.
struct TreeFacts: Equatable, Sendable {
    var bytes: Int64 = 0
    var files = 0
    var newest: Date?
    /// The files counted in `bytes` when the walk was asked to collect them (`olderThan` with `collect: true`).
    var listed: [FileStamp] = []
    /// Why the walk is incomplete — an unreadable item, missing metadata, the time budget — or nil when every item was read.
    var gap: String?
    /// The first name anywhere inside that the caller's `alarm` matched, folders and links included.
    var alarm: String?
    /// The first name anywhere inside that the caller's `notice` matched, the same way.
    var noticed: String?

    var isComplete: Bool { gap == nil }

    /// Time since the newest file changed. nil when the walk is incomplete or found no file: both mean "cannot tell".
    func idle(at now: Date) -> TimeInterval? {
        guard isComplete, let newest else { return nil }
        return now.timeIntervalSince(newest)
    }
}

/// Walks a folder for its allocated size and newest regular file, without following symbolic links.
/// - Important: The folder's own modification date is never used. It can lag the newest file inside by months, which
///   would make a cache in use look abandoned.
/// - Warning: Any unreadable item, missing date or budget hit leaves `gap` set. The old `FolderScanner` skipped such items
///   silently; that is fine for a size label and unsafe for a delete decision.
enum TreeWalk {
    private static let keys: Set<URLResourceKey> = [
        .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey, .totalFileAllocatedSizeKey,
    ]

    /// - Parameters:
    ///   - olderThan: count only files last changed before this date in `bytes` and `files`; `newest` still sees all.
    ///   - collect: also list those files, with their identity, for deleting exactly them later.
    ///   - alarm: items to report in `alarm` wherever they are, so a deep key or disk image can keep the whole row; it is
    ///     told whether the item is a folder.
    ///   - notice: items to report in `noticed` the same way, for a milder consequence.
    ///   - until: the walk ends by then whatever `budget` leaves; past it nothing is read and nothing is asked.
    static func inspect(_ url: URL, budget: Duration = .seconds(60), until: ContinuousClock.Instant? = nil, olderThan cutoff: Date? = nil,
                        collect: Bool = false, alarm: (@Sendable (URL, Bool) -> Bool)? = nil, notice: (@Sendable (URL) -> Bool)? = nil,
                        clock: ContinuousClock = ContinuousClock()) -> TreeFacts {
        var facts = TreeFacts()
        if let until, clock.now >= until {
            facts.gap = "시간 초과"
            return facts
        }
        guard let top = try? url.resourceValues(forKeys: keys) else {
            facts.gap = "읽을 수 없음"
            return facts
        }
        if top.isSymbolicLink == true {
            facts.gap = "심볼릭 링크"
            return facts
        }
        // The item itself counts too: a key file can sit directly in a cache folder's parent.
        if let alarm, alarm(url, top.isDirectory == true) { facts.alarm = url.lastPathComponent }
        if let notice, notice(url) { facts.noticed = url.lastPathComponent }
        if top.isRegularFile == true {
            add(top, at: url, to: &facts, cutoff: cutoff, collect: collect)
            return facts
        }

        var failure: String?
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [],
                                                          errorHandler: { item, error in
                                                              failure = "\(item.lastPathComponent): \(error.localizedDescription)"
                                                              return false
                                                          })
        else {
            facts.gap = "열 수 없음"
            return facts
        }
        let limit = clock.now.advanced(by: budget)
        let deadline = until.map { min(limit, $0) } ?? limit
        for case let item as URL in walker {
            // Checked on every item, folders included, so a tree of empty folders cannot outrun the budget.
            if clock.now >= deadline {
                facts.gap = "시간 초과"
                return facts
            }
            guard let values = try? item.resourceValues(forKeys: keys) else {
                facts.gap = "읽을 수 없음: \(item.lastPathComponent)"
                return facts
            }
            // Before the regular-file filter: disk images and archives are often folders (.sparsebundle, .xcarchive).
            if facts.alarm == nil, let alarm, alarm(item, values.isDirectory == true) { facts.alarm = item.lastPathComponent }
            if facts.noticed == nil, let notice, notice(item) { facts.noticed = item.lastPathComponent }
            guard values.isSymbolicLink != true, values.isRegularFile == true else { continue }
            guard values.contentModificationDate != nil else {
                facts.gap = "날짜 없음: \(item.lastPathComponent)"
                return facts
            }
            add(values, at: item, to: &facts, cutoff: cutoff, collect: collect)
        }
        if let failure { facts.gap = failure }
        return facts
    }

    /// Walks several folders at once, results in the same order. Hundreds of build caches walked one after another took
    /// minutes; an SSD answers many folders in parallel.
    static func inspectAll(_ urls: [URL], budget: Duration = .seconds(60), until: ContinuousClock.Instant? = nil,
                           alarm: (@Sendable (URL, Bool) -> Bool)? = nil, notice: (@Sendable (URL) -> Bool)? = nil) -> [TreeFacts] {
        let results = OSAllocatedUnfairLock(initialState: [TreeFacts?](repeating: nil, count: urls.count))
        DispatchQueue.concurrentPerform(iterations: urls.count) { index in
            let facts = inspect(urls[index], budget: budget, until: until, alarm: alarm, notice: notice)
            results.withLock { $0[index] = facts }
        }
        return results.withLock { found in found.map { $0 ?? TreeFacts(gap: "검사하지 못함") } }
    }

    private static func add(_ values: URLResourceValues, at url: URL, to facts: inout TreeFacts, cutoff: Date?, collect: Bool) {
        guard let modified = values.contentModificationDate else {
            facts.gap = "날짜 없음"
            return
        }
        if modified > (facts.newest ?? .distantPast) { facts.newest = modified }
        if let cutoff, modified >= cutoff { return }
        let bytes = Int64(values.totalFileAllocatedSize ?? 0)
        facts.bytes += bytes
        facts.files += 1
        guard collect else { return }
        let path = url.path(percentEncoded: false)
        guard let identity = FileIdentity.of(path) else {
            facts.gap = "읽을 수 없음: \(url.lastPathComponent)"
            return
        }
        facts.listed.append(FileStamp(path: path, identity: identity, modified: modified, bytes: bytes))
    }
}

/// Which build caches borrow package objects from which: a SwiftPM checkout's `.git/objects/info/alternates` names the
/// object folders it reads from, often another build cache's `SourcePackages/repositories/<package>/objects`. Deleting
/// that other cache breaks the borrower's checkout for good.
struct CheckoutAlternates: Sendable {
    /// Borrowers by lender: a lender cache's resolved path → the alternates files that name a folder inside it.
    var borrowers: [String: Set<String>] = [:]
    /// Caches holding a checkout whose every alternates line names a folder that is gone.
    var broken: Set<String> = []

    private static let marker = "/SourcePackages/repositories/"

    /// Reads every checkout's alternates in `caches` (build cache folders, resolved paths).
    static func read(caches: [URL]) -> CheckoutAlternates {
        var map = CheckoutAlternates()
        for cache in caches {
            let path = cache.path(percentEncoded: false)
            let checkouts = cache.appending(path: "SourcePackages/checkouts")
            for checkout in ScanSupport.children(of: checkouts) ?? [] {
                let file = checkout.appending(path: ".git/objects/info/alternates").path(percentEncoded: false)
                guard let named = lines(file) else { continue }
                if !named.isEmpty, named.allSatisfy({ !FileManager.default.fileExists(atPath: $0) }) { map.broken.insert(path) }
                for target in named {
                    guard let lender = lender(of: target), !same(lender, path) else { continue }
                    map.borrowers[lender, default: []].insert(file)
                }
            }
        }
        return map
    }

    /// The folders an alternates file names, relative lines resolved against its `objects` folder; nil when unreadable.
    static func lines(_ file: String) -> [String]? {
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return nil }
        let objects = ((file as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        return text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { $0.hasPrefix("/") ? $0 : (objects as NSString).appendingPathComponent($0) }
            .map { ($0 as NSString).standardizingPath }
    }

    /// The build cache a named folder sits in: everything before `/SourcePackages/repositories/`.
    static func lender(of folder: String) -> String? {
        folder.range(of: marker, options: [.caseInsensitive, .backwards]).map { range in
            let cache = String(folder[..<range.lowerBound])
            return PathGuard.realPath(URL(fileURLWithPath: cache)) ?? cache
        }
    }

    /// The build cache an alternates file belongs to: everything before `/SourcePackages/checkouts/`.
    static func cache(ofBorrower file: String) -> String {
        file.range(of: "/SourcePackages/checkouts/", options: [.caseInsensitive, .backwards]).map { String(file[..<$0.lowerBound]) } ?? file
    }

    /// The same cache, whatever case or link spelled it, and with or without the trailing "/" a listed folder's URL has.
    static func same(_ a: String, _ b: String) -> Bool { folded(a) == folded(b) }

    /// Whether an alternates file lies inside `lender` itself: a checkout reading its own cache's mirror, which goes with
    /// the cache and so never keeps it.
    /// - Important: Case counts here, unlike in `same`: calling a borrower inside is what lets its lender go, so a
    ///   spelling that matches only once case is folded, as a folder beside it on a case-sensitive volume, keeps it.
    static func isInside(_ file: String, _ lender: String) -> Bool { trimmed(file).hasPrefix(trimmed(lender) + "/") }

    private static func trimmed(_ path: String) -> String { path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path }
    private static func folded(_ path: String) -> String { PathKey.fold(trimmed(path)) }

    /// Whether the alternates file still names a folder inside `lender`. nil when the file cannot be read for another
    /// reason than being gone: then it may still borrow.
    static func stillBorrows(_ file: String, from lender: String) -> Bool? {
        // Gone only when the system says so; a folder on the way that cannot be entered (no permission) says nothing.
        var info = stat()
        if stat(file, &info) != 0 { return errno == ENOENT || errno == ENOTDIR ? false : nil }
        guard let named = lines(file) else { return nil }
        return named.contains { Self.lender(of: $0).map { same($0, lender) } ?? false }
    }
}

/// The borrowers seen so far, kept on disk so a lender stays protected after a restart, and when its borrower sits
/// where only the expanded scan looks.
/// - Important: Every write is read, merge, write under an exclusive lock on a separate lock file, so two scans (or the
///   app and `--scan-report`) finishing in either order never lose a borrower the other added. A borrower is forgotten
///   only when a scan read its alternates file again and found it gone or no longer naming the lender.
struct BorrowerMemory: Sendable {
    struct Edge: Codable, Hashable, Sendable {
        /// The lender build cache's resolved path.
        let lender: String
        /// The borrowing checkout's alternates file.
        let borrower: String
    }

    enum State: Equatable, Sendable {
        /// No file yet: the first run.
        case none
        /// A file that does not read as this version's memory.
        case corrupt
        case edges(Set<Edge>)

        var known: Set<Edge> { if case .edges(let edges) = self { edges } else { [] } }
    }

    private struct Stored: Codable {
        var schemaVersion: Int
        var edges: [Edge]
    }

    static let schemaVersion = 1
    let url: URL

    static func live() -> BorrowerMemory {
        BorrowerMemory(url: FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Macbak/borrowers.json"))
    }

    func load() -> State {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return .none }
        guard let data = try? Data(contentsOf: url), let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.schemaVersion == Self.schemaVersion else { return .corrupt }
        // Older scans stored a cache's own checkout as its borrower; it goes with the cache, so it is not read, and the
        // next commit writes the file without it.
        return .edges(Set(stored.edges.filter { !CheckoutAlternates.isInside($0.borrower, $0.lender) }))
    }

    /// Adds `seen` and drops `gone` against what the file holds now, under the lock. Returns what it wrote, or nil when
    /// the lock or the write failed (the file is then as before).
    @discardableResult
    func commit(seen: Set<Edge>, gone: Set<Edge>) -> Set<Edge>? {
        let folder = url.deletingLastPathComponent()
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return nil }
        let lockPath = folder.appending(path: url.deletingPathExtension().lastPathComponent + ".lock").path(percentEncoded: false)
        let lock = open(lockPath, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { return nil }
        defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { return nil }
        defer { flock(lock, LOCK_UN) }
        // A borrower found gone before the lock may have been seen again since; only one still gone now is dropped.
        let merged = load().known.union(seen).subtracting(gone.filter { CheckoutAlternates.stillBorrows($0.borrower, from: $0.lender) == false })
        let stored = Stored(schemaVersion: Self.schemaVersion, edges: merged.sorted { ($0.lender, $0.borrower) < ($1.lender, $1.borrower) })
        guard let data = try? JSONEncoder().encode(stored), (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        return merged
    }

    /// Alternates files that name a folder inside `lender` now: the remembered ones and those in the usual build cache
    /// folders, each read again. One that cannot be read counts as borrowing.
    static func liveBorrowers(of lender: String, memory: BorrowerMemory, home: URL) -> [String] {
        var files = Set(memory.load().known.filter { CheckoutAlternates.same($0.lender, lender) }.map(\.borrower))
        var caches: [URL] = []
        if let root = ScanSupport.resolved(home, "Library/Developer/Xcode/DerivedData") { caches += ScanSupport.children(of: root) ?? [] }
        if let root = ScanSupport.resolved(home, "Library/Developer/XcodeBuildMCP/workspaces") {
            for workspace in ScanSupport.children(of: root) ?? [] { caches += ScanSupport.children(of: workspace.appending(path: "DerivedData")) ?? [] }
        }
        for (key, found) in CheckoutAlternates.read(caches: caches).borrowers where CheckoutAlternates.same(key, lender) { files.formUnion(found) }
        return files.filter { CheckoutAlternates.stillBorrows($0, from: lender) != false }.sorted()
    }

    /// Reads the remembered borrowers again: those still naming their lender stay, those gone are returned to forget.
    /// One that cannot be read stays.
    static func recheck(_ edges: Set<Edge>) -> (live: Set<Edge>, gone: Set<Edge>) {
        var live: Set<Edge> = [], gone: Set<Edge> = []
        for edge in edges {
            if CheckoutAlternates.stillBorrows(edge.borrower, from: edge.lender) == false { gone.insert(edge) } else { live.insert(edge) }
        }
        return (live, gone)
    }
}
