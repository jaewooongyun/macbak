import Darwin
import Foundation

/// Which app each process works for, so an app's memory includes its helpers (renderers, extensions, language servers).
enum ProcessOwnership {
    typealias Responsible = @Sendable (pid_t) -> pid_t?

    /// `responsibility_get_pid_responsible_for_pid` from libSystem, which Activity Monitor's grouping rests on; nil on a
    /// macOS without it, and then nothing is guessed.
    static let live: Responsible? = {
        // RTLD_DEFAULT, which Swift does not import.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        typealias Function = @convention(c) (pid_t) -> pid_t
        let function = unsafeBitCast(symbol, to: Function.self)
        return { pid in
            let responsible = function(pid)
            return responsible > 0 ? responsible : nil
        }
    }()

    enum State: Equatable, Sendable {
        /// Not read: the memory screen is not shown.
        case off
        /// Only each app's own process counted, for this reason.
        case unknown(String)
        /// Helpers added; `unread` processes in the apps' groups had no readable memory.
        case measured(unread: Int)

        /// The memory list's note on what its figures include.
        var note: String {
            switch self {
            case .off: "앱 본체 프로세스 기준"
            case .unknown(let reason): reason
            case .measured(let unread): unread > 0 ? "보조 프로세스 포함 · 일부 확인 못 함" : "보조 프로세스 포함"
            }
        }
    }

    /// Who each listed process works for, and how many the function could not place.
    struct Owners: Sendable, Equatable {
        var owner: [pid_t: pid_t]
        var unplaced: Int
    }

    /// One call per listed process, so it runs off the main actor with the snapshot.
    static func owners(_ snapshot: ProcessSnapshot, responsible: Responsible) -> Owners {
        var owners = Owners(owner: [:], unplaced: 0)
        for pid in snapshot.entries.keys {
            if let owner = responsible(pid) { owners.owner[pid] = owner } else { owners.unplaced += 1 }
        }
        return owners
    }

    /// Each app's pid and the pids it is responsible for, itself included.
    static func members(_ owners: Owners, apps: Set<pid_t>) -> [pid_t: Set<pid_t>] {
        var members = Dictionary(uniqueKeysWithValues: apps.map { ($0, Set([$0])) })
        for (pid, owner) in owners.owner { members[owner]?.insert(pid) }
        return members
    }

    /// The apps with their helpers' memory added, heaviest in total first; unchanged, with the reason, when the processes
    /// could not all be listed or this macOS has no way to tell whose they are.
    static func apply(_ apps: [AppMemory], snapshot: ProcessSnapshot?, owners: Owners?) -> (apps: [AppMemory], state: State) {
        guard let snapshot, !snapshot.truncated else { return (apps, .unknown("프로세스 목록을 다 읽지 못해 앱 본체만 잽니다")) }
        guard let owners else { return (apps, .unknown("이 macOS 에서는 보조 프로세스를 앱에 묶지 못해 앱 본체만 잽니다")) }
        let members = members(owners, apps: Set(apps.map(\.id)))
        var unread = 0
        let summed = apps.map { app -> AppMemory in
            var app = app
            app.helperPIDs = (members[app.id] ?? []).subtracting([app.id])
            app.helpers = app.helperPIDs.reduce(0) { sum, pid in
                guard let footprint = snapshot.entries[pid]?.footprint else { unread += 1; return sum }
                return sum + footprint
            }
            return app
        }
        return (summed.sorted { $0.total > $1.total }, .measured(unread: unread))
    }

    /// The memory of every process in any of `groups`, each counted once however many groups hold it.
    static func union(_ groups: [Set<pid_t>], in snapshot: ProcessSnapshot) -> UInt64 {
        groups.reduce(into: Set<pid_t>()) { $0.formUnion($1) }.reduce(0) { $0 + (snapshot.entries[$1]?.footprint ?? 0) }
    }
}
