import Foundation

/// What `simctl` goes on deleting after a run returns, and the wait for it before free space is measured again.
/// `simctl delete` moves a device folder to `Deleting-<UUID>` in the user temp folder and the simulator service removes it
/// over minutes: a run that deleted 155.8 GB of simulators measured +27 GB at once and +153 GB eleven minutes later
/// (2026-11-18). A runtime delete goes on in the background too.
/// - Important: Done only when it is proven. A simulator delete is done once the traces seen right after it are gone
///   and its data folder is gone; a delete whose traces were never seen proves nothing, since an empty set or another
///   process's traces cannot stand in for it.
struct BackgroundDeletion: Sendable {
    /// One delete the executor ran, with what it saw right after.
    enum Pending: Sendable, Equatable {
        /// `traces`: `Deleting-*` names new right after this delete, beyond the run's baseline and earlier deletes'
        /// traces; nil when the folder could not be read.
        case simulator(udid: String, dataPath: String, traces: Set<String>?)
        case runtime(identifier: String, path: String)
    }

    enum State: Sendable, Equatable {
        case waiting
        /// Proven gone; free space measured after.
        case settled
        /// A trace never seen, or a listing or folder that could not be read.
        case unconfirmed
        /// Past the limit, still there.
        case stillDeleting
        case cancelled
    }

    struct Dependencies: Sendable {
        var deletingNames: @Sendable () -> Set<String>?
        var exists: @Sendable (String) -> Bool
        var runtimes: @Sendable () -> [SimulatorRuntimes.Runtime]?
        var freeSpace: @Sendable () -> Int64?
        var sleep: @Sendable (Duration) async throws -> Void
        var audit: CleanupAudit
        var interval: Duration = .seconds(5)
        /// Fifteen minutes of five-second checks.
        var checks = 180

        static func live() -> Dependencies {
            Dependencies(deletingNames: { BackgroundDeletion.deletingNames() }, exists: { FileManager.default.fileExists(atPath: $0) },
                         runtimes: { SimulatorRuntimes.readRuntimes() }, freeSpace: { SystemReader.disk()?.available },
                         sleep: { try await Task.sleep(for: $0) }, audit: .live())
        }
    }

    let dependencies: Dependencies

    init(dependencies: Dependencies = .live()) {
        self.dependencies = dependencies
    }

    /// Waits off the main actor until every pending delete is proven gone, then measures free space once more and records
    /// it; `progress` gets each reading taken while waiting.
    /// - Parameter free: the run's own reading right after its last delete.
    /// - Returns: the final state and the latest free-space reading; nil when nothing is pending, at once.
    func wait(for pending: [Pending], free: Int64?, progress: @Sendable (Int64?) async -> Void = { _ in }) async -> (state: State, free: Int64?)? {
        guard !pending.isEmpty else { return nil }
        let started = Date.now
        var free = free
        for check in 0..<dependencies.checks {
            switch progressOf(pending) {
            case .settled:
                let after = dependencies.freeSpace()
                try? dependencies.audit.append(["event": "settled", "time": ISO8601DateFormatter().string(from: .now),
                                                "freeAfter": after.map(String.init) ?? "?",
                                                "waited": String(format: "%.0f", Date.now.timeIntervalSince(started))])
                return (.settled, after)
            case .unconfirmed:
                return (.unconfirmed, free)
            default:
                break
            }
            // The first check comes right after the run, which has just measured.
            if check > 0 {
                free = dependencies.freeSpace()
                await progress(free)
            }
            do { try await dependencies.sleep(dependencies.interval) } catch { return (.cancelled, free) }
        }
        return (.stillDeleting, free)
    }

    /// Where the pending deletes stand now: waiting, all proven gone, or not provable.
    func progressOf(_ pending: [Pending]) -> State {
        var waiting = false
        let simulators = pending.compactMap { if case .simulator(_, let path, let traces) = $0 { (path, traces) } else { nil } }
        if !simulators.isEmpty {
            guard let names = dependencies.deletingNames() else { return .unconfirmed }
            for (path, traces) in simulators {
                guard let traces, !traces.isEmpty else { return .unconfirmed }
                if !traces.isDisjoint(with: names) || dependencies.exists(path) { waiting = true }
            }
        }
        let runtimes = pending.compactMap { if case .runtime(let identifier, let path) = $0 { (identifier, path) } else { nil } }
        if !runtimes.isEmpty {
            guard let listed = dependencies.runtimes() else { return .unconfirmed }
            for (identifier, path) in runtimes where listed.contains(where: { $0.identifier == identifier }) || dependencies.exists(path) {
                waiting = true
            }
        }
        return waiting ? .waiting : .settled
    }

    /// `Deleting-*` names in the user temp folder (`getconf DARWIN_USER_TEMP_DIR`), or nil when it cannot be read.
    static func deletingNames() -> Set<String>? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0 else { return nil }
        let folder = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return nil }
        return Set(names.filter { $0.hasPrefix("Deleting-") })
    }

    /// The run's measured gain while waiting or once settled, in the panel's words.
    static func text(_ state: State, freeBefore: Int64?, free: Int64?) -> String {
        let gain = freeBefore.flatMap { before in free.map { $0 - before } }
        let soFar = gain.map { " · 지금까지 \($0 > 0 ? "+" : "")\($0.diskText)" } ?? ""
        switch state {
        case .waiting: return "백그라운드에서 지우는 중" + soFar
        case .settled:
            guard let gain else { return "늘어난 공간을 재지 못했습니다" }
            return gain > 0 ? "실제로 늘어난 공간 +\(gain.diskText) (삭제가 끝난 뒤 측정)" : "여유 공간 변화가 측정되지 않았습니다 (삭제가 끝난 뒤 측정)"
        case .stillDeleting: return "아직 지우는 중이라 끝났는지 확인하지 못했습니다" + soFar
        case .unconfirmed, .cancelled: return "삭제가 끝났는지 확인하지 못했습니다" + soFar
        }
    }
}
