import Foundation

/// Runs on-device model work one job at a time for the whole app, so no two jobs ever load the model side by side.
/// - Important: The turn is held while a job awaits, and handed straight to the next waiter when it ends: an actor
///   method alone would let another call in at every `await`.
/// - Note: A deadline is when the job is cancelled, not when it has ended. Model calls stop cooperatively, so the turn
///   stays taken until the job has really returned; only then does the next one start.
actor ModelSlot {
    enum Priority: Sendable {
        /// The explorer and its vetoes: rows wait on them before they can be ticked.
        case high
        /// Work no row waits on.
        case low
    }

    static let shared = ModelSlot()

    private struct Waiter {
        let id: UInt64
        let priority: Priority
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var busy = false
    private var waiters: [Waiter] = []
    private var nextID: UInt64 = 0

    /// How many callers wait for the turn; for tests.
    var waiting: Int { waiters.count }

    /// Runs `job` when the turn comes.
    /// - Returns: what the job returned, or nil when the caller was cancelled while waiting (the job never ran) or while
    ///   it ran, or when the deadline passed first. A job cancelled that way still runs to its end before the turn moves.
    func run<T: Sendable>(_ priority: Priority, deadline: Duration, _ job: @escaping @Sendable () async -> T) async -> T? {
        guard await acquire(priority) else { return nil }
        defer { release() }
        let work = Task { await job() }
        let timer = Task {
            do { try await Task.sleep(for: deadline) } catch { return }
            work.cancel()
        }
        let result = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        timer.cancel()
        return work.isCancelled ? nil : result
    }

    /// Takes the turn, or waits for it in priority order (high first, then the order of arrival).
    /// - Returns: false when the caller was cancelled; then it does not hold the turn.
    private func acquire(_ priority: Priority) async -> Bool {
        if Task.isCancelled { return false }
        if !busy {
            busy = true
            return true
        }
        nextID += 1
        let id = nextID
        let handed = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters.append(Waiter(id: id, priority: priority, continuation: continuation))
            }
        } onCancel: {
            Task { await self.leave(id) }
        }
        // Cancelled just as the turn came: hand it on rather than run.
        if handed, Task.isCancelled {
            release()
            return false
        }
        return handed
    }

    /// A cancelled waiter leaves the queue; one already handed the turn is not found and gives it back itself.
    private func leave(_ id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }

    private func release() {
        guard let index = waiters.firstIndex(where: { $0.priority == .high }) ?? waiters.indices.first else {
            busy = false
            return
        }
        // Still busy: the turn goes straight to the next waiter.
        waiters.remove(at: index).continuation.resume(returning: true)
    }
}
