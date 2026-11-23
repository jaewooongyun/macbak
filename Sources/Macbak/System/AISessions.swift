import AppKit
import Darwin

/// A Claude session idle for longer than the Settings age, with the processes it started.
struct IdleSession: Identifiable, Sendable, Equatable {
    let record: AISessions.Record
    /// Its descendants as they were when found; start and path tell a later process with the same pid apart.
    let helpers: [pid_t: AISessions.Identity]
    let footprint: UInt64

    var id: pid_t { record.pid }
    var members: Set<pid_t> { Set(helpers.keys).union([record.pid]) }
}

/// Finds Claude sessions left idle, and ends one only after reading it again.
/// - Important: Session files are read for their state fields only; the `.key` files beside them are never opened,
///   process arguments are never read, and a session's name is shown but never kept.
enum AISessions {
    struct Identity: Sendable, Equatable {
        let start: Date?
        let path: String?
    }

    struct Record: Sendable, Equatable {
        let pid: pid_t
        /// When its process started, as the session wrote it: ties the pid to this session.
        let procStart: Date
        let status: String
        let updatedAt: Date
        let kind: String
        let jobId: String?
        /// For the screen only.
        let name: String
    }

    /// The `*.json` files in `folder`; nil when the folder cannot be listed. A file that does not parse is left out,
    /// so its session is never offered.
    static func read(_ folder: String, load: (String) -> Data? = { FileManager.default.contents(atPath: $0) }) -> [Record]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return nil }
        return names.filter { $0.hasSuffix(".json") }.sorted().compactMap { load(folder + "/" + $0).flatMap(parse) }
    }

    static func parse(_ data: Data) -> Record? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let pid = object["pid"] as? Int, pid > 0, pid <= Int(Int32.max),
              let procStart = (object["procStart"] as? String).flatMap(parseStart),
              let status = object["status"] as? String, let updated = object["updatedAt"] as? Double,
              let kind = object["kind"] as? String, let name = object["name"] as? String else { return nil }
        return Record(pid: pid_t(pid), procStart: procStart, status: status, updatedAt: Date(timeIntervalSince1970: updated / 1000),
                      kind: kind, jobId: object["jobId"] as? String, name: name)
    }

    /// `procStart`, written like `ps -o lstart` in UTC ("Thu Nov 12 00:13:47 2026"), to the second. Read in the wrong
    /// zone it matches no process start, which protects the session.
    static func parseStart(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter.date(from: text.split(separator: " ").joined(separator: " "))
    }

    /// The `field` of each job's state file, by job id; a job whose state cannot be read is missing.
    static func jobStates(_ ids: [String], root: String, store: JobStore, load: (String) -> Data? = { FileManager.default.contents(atPath: $0) }) -> [String: String] {
        var states: [String: String] = [:]
        for id in Set(ids) where !id.contains("/") && id != ".." {
            guard let data = load(root + "/" + id + "/" + store.stateFile),
                  let state = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?[store.field] as? String else { continue }
            states[id] = state
        }
        return states
    }

    struct Inputs: Sendable {
        var records: [Record]
        var snapshot: ProcessSnapshot
        /// The reading before; activity is measured between the two, so without one nothing is offered.
        var previous: ProcessSnapshot?
        var jobStates: [String: String]
        var store: JobStore
        var idleAge: TimeInterval
        var now: Date
        /// Claude's executable names, from the catalog.
        var names: Set<String>
        var me: uid_t = getuid()
    }

    /// Claude Code's job store and executable names, from the catalog.
    static let store = AITool.claudeCode.jobs
    static let names = Set(AITool.claudeCode.process.names)

    /// This person's Claude sessions; nil when the folder cannot be listed.
    static func readLive() -> [Record]? {
        guard let folder = store?.sessions else { return nil }
        return read(NSHomeDirectory() + "/" + folder)
    }

    /// The states of these jobs in Claude Code's job store.
    static func jobStatesLive(_ ids: [String]) -> [String: String] {
        guard let store else { return [:] }
        return jobStates(ids, root: NSHomeDirectory() + "/" + store.root, store: store)
    }

    /// Readings closer than this say too little about whether a helper is working.
    static let minimumWindow: TimeInterval = 5
    /// A helper using this share of one core between the readings is working.
    static let busyShare = 0.01

    /// Idle sessions, heaviest first.
    static func candidates(_ inputs: Inputs) -> [IdleSession] {
        inputs.records.compactMap { record in
            guard refusal(record, inputs) == nil, let group = group(of: record, in: inputs) else { return nil }
            let members = Set(group.keys).union([record.pid])
            return IdleSession(record: record, helpers: group.mapValues { Identity(start: $0.start, path: $0.path) },
                               footprint: ProcessOwnership.union([members], in: inputs.snapshot))
        }
        .sorted { ($0.footprint, $1.record.pid) > ($1.footprint, $0.record.pid) }
    }

    /// Why `record`'s session may not be offered or ended; nil when every check passes.
    static func refusal(_ record: Record, _ inputs: Inputs) -> String? {
        guard record.status == "idle" else { return "작업 중인 세션입니다" }
        guard inputs.now.timeIntervalSince(record.updatedAt) >= inputs.idleAge else { return "최근에 쓴 세션입니다" }
        guard let root = inputs.snapshot.entries[record.pid], root.uid == inputs.me, root.start != nil,
              let name = root.name, inputs.names.contains(name) else { return "세션 프로세스를 확인하지 못했습니다" }
        guard isRoot(record, in: inputs.snapshot, names: inputs.names) else { return "다른 프로세스로 바뀌었습니다" }
        if record.kind == "bg" {
            guard let job = record.jobId, let state = inputs.jobStates[job] else { return "작업 상태를 읽지 못했습니다" }
            if inputs.store.isAlive(state) { return "작업이 아직 진행 중입니다" }
        }
        guard let group = group(of: record, in: inputs) else { return "세션이 띄운 프로세스를 다 확인하지 못했습니다" }
        for helper in group.values {
            guard let started = helper.start else { return "세션이 띄운 프로세스를 다 확인하지 못했습니다" }
            if started > record.updatedAt { return "마지막 활동 뒤에 시작한 프로세스가 있습니다" }
        }
        guard let previous = inputs.previous, inputs.snapshot.taken.timeIntervalSince(previous.taken) >= minimumWindow else {
            return "활동을 재는 중입니다"
        }
        let window = inputs.snapshot.taken.timeIntervalSince(previous.taken)
        for helper in group.values {
            guard let earlier = previous.entries[helper.pid], earlier.start == helper.start,
                  let before = earlier.cpu, let after = helper.cpu, after >= before else { return "보조 프로세스의 활동을 확인하지 못했습니다" }
            if Double(after - before) / 1e9 >= window * busyShare { return "보조 프로세스가 일하고 있습니다" }
        }
        return nil
    }

    /// Whether `record`'s pid is still its session's process: a Claude executable that started in the second the session wrote.
    static func isRoot(_ record: Record, in snapshot: ProcessSnapshot, names: Set<String>) -> Bool {
        guard let entry = snapshot.entries[record.pid], let start = entry.start, let name = entry.name else { return false }
        return names.contains(name) && start.timeIntervalSince1970.rounded(.down) == record.procStart.timeIntervalSince1970
    }

    /// The root's descendants, less any other live session's root and what runs under it; nil when the tree cannot be read.
    /// A stale record whose pid now belongs to one of this session's own helpers sets nothing aside.
    static func group(of record: Record, in inputs: Inputs) -> [pid_t: ProcessSnapshot.Entry]? {
        let snapshot = inputs.snapshot
        guard !snapshot.truncated, var pids = snapshot.descendants(of: record.pid) else { return nil }
        for other in inputs.records where other.pid != record.pid && pids.contains(other.pid) && isRoot(other, in: snapshot, names: inputs.names) {
            guard let theirs = snapshot.descendants(of: other.pid) else { return nil }
            pids.subtract(theirs.union([other.pid]))
        }
        return pids.reduce(into: [:]) { $0[$1] = snapshot.entries[$1] }
    }

    struct Outcome: Equatable, Sendable {
        var refused: String?
        var rootEnded = false
        var helpersEnded = 0
        var helpersLeft = 0

        /// The run panel's reason beside the step; nil when everything ended.
        var reason: String? {
            if let refused { return refused }
            guard rootEnded else { return "세션이 끝나지 않음" }
            guard helpersLeft > 0 else { return nil }
            return "남은 보조 \(helpersEnded)개 끝냄 · \(helpersLeft)개 끝나지 않음"
        }
    }

    /// How `end` reads and signals; tests replace every part, so no real process is ever signalled.
    struct Ending: Sendable {
        static func live(idleAge: TimeInterval) -> Ending {
            Ending(read: {
                await Task.detached(priority: .utility) { () -> Inputs? in
                    guard let store, let records = readLive(), let snapshot = ProcessSnapshot.capture() else { return nil }
                    return Inputs(records: records, snapshot: snapshot, jobStates: jobStatesLive(records.compactMap(\.jobId)), store: store,
                                  idleAge: idleAge, now: .now, names: names)
                }.value
            })
        }

        /// A fresh reading, without `previous`.
        var read: @Sendable () async -> Inputs?
        var snapshot: @Sendable () -> ProcessSnapshot? = { ProcessSnapshot.capture() }
        var signal: @Sendable (pid_t, Int32) -> Int32 = { kill($0, $1) }
        /// Throws when the run is cancelled, which stops the waiting.
        var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    }

    /// Reads it twice, five and a half seconds apart, and ends it only if it is the same session, untouched since it was
    /// listed and still idle by every check. Then SIGTERM to the root, and once the root has gone, SIGTERM to each of its
    /// original helpers still running as the same process, unless it now runs under another live session.
    static func end(_ session: IdleSession, using ending: Ending) async -> Outcome {
        guard let first = await ending.read() else { return Outcome(refused: "확인하지 못했습니다") }
        do { try await ending.sleep(.milliseconds(5500)) } catch { return Outcome(refused: "취소됨") }
        guard var now = await ending.read() else { return Outcome(refused: "확인하지 못했습니다") }
        now.previous = first.snapshot
        let pid = session.record.pid
        guard let record = now.records.first(where: { $0.pid == pid }) else { return Outcome(refused: "세션이 이미 끝났습니다") }
        guard record.procStart == session.record.procStart, record.updatedAt == session.record.updatedAt else {
            return Outcome(refused: "그사이 세션이 쓰였습니다")
        }
        if let reason = refusal(record, now) { return Outcome(refused: reason) }
        guard ending.signal(pid, SIGTERM) == 0 else { return Outcome(refused: "종료 요청을 보내지 못함") }

        var after: ProcessSnapshot?
        for _ in 0..<10 {
            do { try await ending.sleep(.milliseconds(500)) } catch { break }
            if let snapshot = ending.snapshot(), !snapshot.truncated,
               snapshot.hasEnded(pid, isSame: { $0.timeIntervalSince1970.rounded(.down) == record.procStart.timeIntervalSince1970 }) {
                after = snapshot
                break
            }
        }
        guard let after else { return Outcome() }

        // A helper launchd adopted when the root ended is still this session's; one under another live session is not.
        var others: Set<pid_t> = []
        for other in now.records where other.pid != pid {
            if isRoot(other, in: after, names: now.names) {
                guard let theirs = after.descendants(of: other.pid) else { return Outcome(rootEnded: true, helpersLeft: session.helpers.count) }
                others.formUnion(theirs.union([other.pid]))
            } else if after.hidden.contains(other.pid) || after.entries[other.pid].map({ $0.start == nil || $0.name == nil }) == true {
                // Another session that cannot be told apart from a stranger may own some of them: none is signalled.
                return Outcome(rootEnded: true, helpersLeft: session.helpers.count)
            }
        }
        // Signalled: those still the same process. Left unsignalled and counted as left: those not shown to have ended.
        var remaining: [pid_t: Identity] = [:]
        var unknown = 0
        for (helper, identity) in session.helpers where !others.contains(helper) {
            if let entry = after.entries[helper], entry.start == identity.start, entry.path == identity.path {
                remaining[helper] = identity
            } else if !after.hasEnded(helper, isSame: { $0 == identity.start }) {
                unknown += 1
            }
        }
        var left = remaining.filter { ending.signal($0.key, SIGTERM) == 0 }
        let unsent = remaining.count - left.count
        let signalled = left.count
        for _ in 0..<10 where !left.isEmpty {
            do { try await ending.sleep(.milliseconds(500)) } catch { break }
            guard let snapshot = ending.snapshot() else { continue }
            left = left.filter { helper, identity in !snapshot.hasEnded(helper, isSame: { $0 == identity.start }) }
        }
        return Outcome(rootEnded: true, helpersEnded: signalled - left.count, helpersLeft: left.count + unsent + unknown)
    }
}
