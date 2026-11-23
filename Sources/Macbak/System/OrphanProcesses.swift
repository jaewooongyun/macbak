import AppKit
import Darwin

/// A developer tool still running after whatever started it went away: launchd adopted it and its process group's
/// leader is gone. Shown on the memory screen for a person to end.
struct OrphanProcess: Identifiable, Sendable, Equatable {
    let pid: pid_t
    let start: Date
    let path: String
    let footprint: UInt64?

    var id: pid_t { pid }
    var name: String { (path as NSString).lastPathComponent }

    /// The same process: pid, start and executable; its memory changes from one reading to the next.
    func isSame(as other: OrphanProcess) -> Bool { pid == other.pid && start == other.start && path == other.path }
}

/// Finds orphaned developer tools, and ends one only after reading it again.
/// - Important: Only an executable under a developer tool location qualifies, and every field the decision needs must
///   have been read: what cannot be confirmed is left running.
enum OrphanProcesses {
    /// A process this young may have detached on purpose a moment ago.
    static let minimumAge: TimeInterval = 600

    /// Where developer tools live: Xcode's and the command line tools' toolchains, Homebrew and per-user version managers.
    static func isDeveloperTool(_ path: String, home: String) -> Bool {
        if path.range(of: #"/Xcode[^/]*\.app/Contents/Developer/"#, options: .regularExpression) != nil { return true }
        let roots = ["/Library/Developer/CommandLineTools/", "/Library/Developer/Toolchains/", "/opt/homebrew/Cellar/", "/usr/local/Cellar/"]
            + ["Library/Developer/Toolchains/", ".nvm/versions/", ".volta/tools/", ".bun/", ".pyenv/versions/", ".local/share/uv/",
               ".cargo/bin/", ".rustup/toolchains/", ".sdkman/candidates/"].map { home + "/" + $0 }
        return roots.contains { path.hasPrefix($0) }
    }

    /// What the decision reads, taken at one moment.
    struct Inputs: Sendable {
        var snapshot: ProcessSnapshot
        /// pids launchd runs as this person's services; nil when either list could not be read.
        var services: Set<pid_t>?
        /// Every running application's pid and bundle folder.
        var apps: [pid_t: String?]
        var home: String
        var now: Date
        var me: uid_t = getuid()
    }

    /// Orphaned developer tools, heaviest first; none when the process list or the service list could not be read whole.
    static func candidates(_ inputs: Inputs) -> [OrphanProcess] {
        inputs.snapshot.entries.values.compactMap { entry in
            guard isOrphan(entry, inputs), let start = entry.start, let path = entry.path else { return nil }
            return OrphanProcess(pid: entry.pid, start: start, path: path, footprint: entry.footprint)
        }
        .sorted { ($0.footprint ?? 0, $1.pid) > ($1.footprint ?? 0, $0.pid) }
    }

    static func isOrphan(_ entry: ProcessSnapshot.Entry, _ inputs: Inputs) -> Bool {
        let snapshot = inputs.snapshot
        guard !snapshot.truncated, let services = inputs.services,
              entry.uid == inputs.me, entry.ppid == 1,
              // The group's leader is gone (a process leading its own group, such as tmux, is its own live leader), and
              // is not one of the processes that could not be read.
              let pgid = entry.pgid, snapshot.entries[pgid] == nil, !snapshot.unreadable.contains(pgid),
              !services.contains(entry.pid), inputs.apps[entry.pid] == nil,
              let start = entry.start, inputs.now.timeIntervalSince(start) >= minimumAge,
              let path = entry.path, isDeveloperTool(path, home: inputs.home), !CleanupRoots.isManagedSoftware(path)
        else { return false }
        // A helper inside a running app's bundle, such as its crash reporter, answers to that app.
        return !inputs.apps.values.contains { bundle in bundle.map { path.hasPrefix($0 + "/") } ?? false }
    }

    /// Why `orphan` may not be ended now, from a fresh reading; nil when it is the same process and still orphaned.
    static func recheck(_ orphan: OrphanProcess, in inputs: Inputs?) -> String? {
        guard let inputs, let entry = inputs.snapshot.entries[orphan.pid] else { return "이미 끝났거나 확인하지 못했습니다" }
        guard entry.start == orphan.start, entry.path == orphan.path else { return "다른 프로세스로 바뀌었습니다" }
        return isOrphan(entry, inputs) ? nil : "더 이상 주인 없는 도구가 아닙니다"
    }

    /// Every running application's pid and bundle folder.
    @MainActor static func runningApps() -> [pid_t: String?] {
        Dictionary(NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0.bundleURL?.path) }, uniquingKeysWith: { first, _ in first })
    }

    /// The pids launchd runs for this person, from both of its lists; nil when either cannot be read.
    static func servicePIDs() -> Set<pid_t>? {
        let uid = getuid()
        var pids: Set<pid_t> = []
        for domain in ["gui/\(uid)", "user/\(uid)"] {
            guard let output = Command.run("/bin/launchctl", ["print", domain], timeout: .seconds(5)), output.status == 0,
                  let listed = parseServices(String(decoding: output.stdout, as: UTF8.self)) else { return nil }
            pids.formUnion(listed)
        }
        return pids
    }

    /// The running pids in `launchctl print`'s `services` block; nil when the block is missing or a row does not parse.
    static func parseServices(_ text: String) -> Set<pid_t>? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let open = lines.firstIndex(of: "\tservices = {"),
              let close = lines[open...].firstIndex(of: "\t}") else { return nil }
        var pids: Set<pid_t> = []
        for line in lines[(open + 1)..<close] {
            guard let first = line.split(whereSeparator: \.isWhitespace).first, let pid = pid_t(first) else { return nil }
            if pid > 0 { pids.insert(pid) }
        }
        return pids
    }

    enum Outcome: Equatable, Sendable {
        case ended
        case refused(String)
        case stillRunning
        case signalFailed

        var reason: String? {
            switch self {
            case .ended: nil
            case .refused(let reason): reason
            case .stillRunning: "끝나지 않음"
            case .signalFailed: "종료 요청을 보내지 못함"
            }
        }
    }

    /// How `end` reads and signals; tests replace every part, so no real process is ever signalled.
    struct Ending: Sendable {
        static let live = Ending(read: {
            let apps = await runningApps()
            return await Task.detached(priority: .utility) {
                ProcessSnapshot.capture().map { Inputs(snapshot: $0, services: servicePIDs(), apps: apps, home: NSHomeDirectory(), now: .now) }
            }.value
        })

        /// Everything the decision reads, for the check right before the signal.
        var read: @Sendable () async -> Inputs?
        /// Only the process list, for seeing whether it ended.
        var snapshot: @Sendable () -> ProcessSnapshot? = { ProcessSnapshot.capture() }
        var signal: @Sendable (pid_t, Int32) -> Int32 = { kill($0, $1) }
        /// Throws when the run is cancelled, which stops the waiting.
        var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    }

    /// Reads it again, asks it to end with SIGTERM, and waits up to five seconds. Never forces it.
    static func end(_ orphan: OrphanProcess, using ending: Ending) async -> Outcome {
        if let reason = recheck(orphan, in: await ending.read()) { return .refused(reason) }
        guard ending.signal(orphan.pid, SIGTERM) == 0 else { return .signalFailed }
        for _ in 0..<10 {
            do { try await ending.sleep(.milliseconds(500)) } catch { return .stillRunning }
            guard let snapshot = ending.snapshot() else { continue }
            if snapshot.hasEnded(orphan.pid, isSame: { $0 == orphan.start }) { return .ended }
        }
        return .stillRunning
    }
}
