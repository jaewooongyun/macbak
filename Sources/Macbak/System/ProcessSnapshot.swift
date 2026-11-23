import Darwin
import Foundation

/// Every process at one moment: what the memory screen sums and what the orphan and session checks judge by.
/// - Important: Each field is nil when it could not be read, and a judgement needing a field it lacks must protect.
///   Process arguments are never read.
struct ProcessSnapshot: Sendable {
    struct Entry: Sendable, Equatable {
        let pid: pid_t
        var ppid: pid_t?
        var pgid: pid_t?
        var uid: uid_t?
        var path: String?
        /// The kernel's name for its executable, readable even when the file behind `path` was replaced; never its arguments.
        var name: String?
        var start: Date?
        var footprint: UInt64?
        /// User plus system CPU time, in nanoseconds.
        var cpu: UInt64?
    }

    var entries: [pid_t: Entry]
    /// Listed processes with no record at all: zombies, or gone since the listing. Another account's process has only its
    /// parent, group and owner (macOS gives no more), so its other fields are nil.
    var unreadable: Set<pid_t> = []
    /// Those of `unreadable` that had not ended (an error other than ESRCH): they may still have children, so the tree
    /// below any process cannot be told.
    var hidden: Set<pid_t> = []
    /// The pid list filled its buffer, so some processes were not listed at all.
    var truncated = false
    let taken: Date

    /// For display only: every listed process read and none left out.
    var complete: Bool { unreadable.isEmpty && !truncated }

    /// Whether the process `isSame` recognises by its start has ended: its pid now lists another start, or it is missing
    /// from a list read to the end without being hidden (a zombie cannot be read, and has ended). An unreadable start
    /// proves nothing.
    func hasEnded(_ pid: pid_t, isSame: (Date) -> Bool) -> Bool {
        if let entry = entries[pid] { return entry.start.map { !isSame($0) } ?? false }
        return !truncated && !hidden.contains(pid)
    }

    static func capture(now: Date = .now) -> ProcessSnapshot? {
        var pids = [pid_t](repeating: 0, count: 16_384)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        guard count > 0 else { return nil }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        var snapshot = ProcessSnapshot(entries: [:], truncated: count >= pids.count, taken: now)
        for pid in pids.prefix(count) where pid > 0 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
                var short = proc_bsdshortinfo()
                let shortSize = Int32(MemoryLayout<proc_bsdshortinfo>.size)
                if proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &short, shortSize) == shortSize {
                    snapshot.entries[pid] = Entry(pid: pid, ppid: pid_t(short.pbsi_ppid), pgid: pid_t(short.pbsi_pgid), uid: short.pbsi_uid)
                } else {
                    snapshot.unreadable.insert(pid)
                    // An ended process's children went to launchd as it exited, so only another error hides a subtree.
                    if errno != ESRCH { snapshot.hidden.insert(pid) }
                }
                continue
            }
            var entry = Entry(pid: pid, ppid: pid_t(info.pbi_ppid), pgid: pid_t(info.pbi_pgid), uid: info.pbi_uid,
                              start: Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1e6))
            entry.name = withUnsafeBytes(of: info.pbi_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
            if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
                entry.path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
            var usage = rusage_info_v4()
            let read = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            if read == 0 {
                entry.footprint = usage.ri_phys_footprint
                entry.cpu = (usage.ri_user_time + usage.ri_system_time) * UInt64(timebase.numer) / UInt64(max(timebase.denom, 1))
            }
            snapshot.entries[pid] = entry
        }
        return snapshot
    }

    /// Every process below `root` by parent links; nil when a parent link on the way could not be read, or a process that
    /// had not ended could not be read at all (its children would be missing).
    func descendants(of root: pid_t) -> Set<pid_t>? {
        guard hidden.isEmpty else { return nil }
        var children: [pid_t: [pid_t]] = [:]
        for entry in entries.values {
            guard let ppid = entry.ppid else { return nil }
            children[ppid, default: []].append(entry.pid)
        }
        var found: Set<pid_t> = []
        var queue = children[root] ?? []
        while let pid = queue.popLast() {
            guard found.insert(pid).inserted else { continue }
            queue += children[pid] ?? []
        }
        return found
    }
}
