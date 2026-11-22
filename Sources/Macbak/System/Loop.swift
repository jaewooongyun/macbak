import Foundation
import Observation
import ServiceManagement

/// Daily run time. A plain value so the due check can be tested without a clock.
struct LoopSchedule: Equatable, Codable {
    var hour = 8
    var minute = 30
    var weekdaysOnly = false

    /// Latest scheduled time at or before `date`.
    func occurrence(onOrBefore date: Date, calendar: Calendar = .current) -> Date? {
        for back in 0...7 {
            if let slot = slot(dayOffset: -back, from: date, calendar), slot <= date { return slot }
        }
        return nil
    }

    /// First scheduled time strictly after `date`.
    func occurrence(after date: Date, calendar: Calendar = .current) -> Date? {
        for ahead in 0...8 {
            if let slot = slot(dayOffset: ahead, from: date, calendar), slot > date { return slot }
        }
        return nil
    }

    /// Due when a scheduled time has passed since both the last run and the moment the loop was turned on.
    /// - Note: A Mac that slept through several scheduled times runs once on wake, not once per missed time.
    func isDue(now: Date, lastRun: Date?, enabledSince: Date, calendar: Calendar = .current) -> Bool {
        guard let slot = occurrence(onOrBefore: now, calendar: calendar), slot >= enabledSince else { return false }
        return lastRun.map { $0 < slot } ?? true
    }

    private func slot(dayOffset: Int, from date: Date, _ calendar: Calendar) -> Date? {
        guard let day = calendar.date(byAdding: .day, value: dayOffset, to: date),
              let slot = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
              !weekdaysOnly || !calendar.isDateInWeekend(slot) else { return nil }
        return slot
    }
}

extension LoopRun {
    /// "얕은 정리 3개", or what an older record counted, or why there is no count.
    var readySummary: String {
        switch source {
        case .cleaned: "얕은 정리 \(readyCount)개"
        case .scan: "\(CleanupStatus.ready.title) \(readyCount)개 (기록만)"
        case .scanFailed: "검사·정리하지 못함"
        case nil: "샘플(이전 기록)"
        }
    }

    /// Whether `readyBytes` is a real amount (cleaned, or found by a real scan).
    var hasAmount: Bool { source == .cleaned || source == .scan }
}

struct LoopRun: Identifiable, Codable, Equatable {
    enum Trigger: String, Codable { case scheduled, manual }
    /// Where `readyCount` and `readyBytes` came from.
    enum Source: String, Codable {
        /// The shallow clean-up ran after a real scan; the counts are what it deleted.
        case cleaned
        /// A real scan of this Mac, recorded only (before the loop cleaned).
        case scan
        /// The scan could not run; the counts are not zero, they are unknown.
        case scanFailed
    }

    var id = UUID()
    let date: Date
    let trigger: Trigger
    let diskAvailable: Int64?
    let memoryUsed: UInt64?
    let memoryPhysical: UInt64?
    let pressure: Int32?
    let readyCount: Int
    let readyBytes: Int64
    /// Optional so history saved before real scans still decodes; nil marks those sample-based counts.
    /// - Warning: Making this required would fail decoding the whole saved array, and the next save would overwrite it.
    var source: Source?
}

/// Runs on schedule while the app (or its menu bar item) is alive: a real scan, then the shallow clean-up — only rows a
/// source vouches for, through the same executor checks as a click — and records what it deleted.
/// - Important: The person decided (2026-11-04) that the loop exists to clean the shallow set on its own. Rows that need
///   a choice or are protected are never touched by it.
@MainActor
@Observable
final class LoopScheduler {
    static let historyLimit = 30

    var enabled: Bool {
        didSet {
            if enabled && !oldValue { enabledSince = .now }
            save()
        }
    }
    var schedule: LoopSchedule {
        didSet { save() }
    }
    private(set) var history: [LoopRun]
    /// A check is scanning; another one is not started until it records.
    private(set) var isChecking = false
    private(set) var loginItemStatus = SMAppService.mainApp.status
    private(set) var loginItemError: String?

    @ObservationIgnored private var enabledSince: Date
    @ObservationIgnored private let system: SystemMonitor
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Scans (and, when `cleans`, cleans) and returns the count and size, or nil when it could not.
    @ObservationIgnored private let scan: (@MainActor () async -> (count: Int, bytes: Int64)?)?
    /// Whether `scan` deletes the shallow set, so records say "얕은 정리" rather than "found".
    @ObservationIgnored private let cleans: Bool

    /// - Parameters:
    ///   - defaults: `nil` keeps everything in memory (used by `--snapshot`).
    ///   - cleans: `scan` runs the shallow clean-up and returns what it deleted.
    ///   - scan: what a run does; without one a run records no counts.
    init(system: SystemMonitor, defaults: UserDefaults? = .standard, cleans: Bool = false,
         scan: (@MainActor () async -> (count: Int, bytes: Int64)?)? = nil) {
        self.system = system
        self.defaults = defaults
        self.cleans = cleans
        self.scan = scan
        let decoder = JSONDecoder()
        enabled = defaults?.bool(forKey: Keys.enabled) ?? false
        schedule = defaults?.data(forKey: Keys.schedule).flatMap { try? decoder.decode(LoopSchedule.self, from: $0) } ?? LoopSchedule()
        history = defaults?.data(forKey: Keys.history).flatMap { try? decoder.decode([LoopRun].self, from: $0) } ?? []
        enabledSince = defaults?.object(forKey: Keys.enabledSince) as? Date ?? .now
    }

    var lastRun: LoopRun? { history.first }
    var nextRun: Date? { enabled ? schedule.occurrence(after: .now) : nil }

    /// Checks every 30 seconds rather than sleeping until the exact time,
    /// so sleep, wake and clock changes are all handled by the same due check.
    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.runIfDue()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func runIfDue(now: Date = .now) {
        guard enabled, schedule.isDue(now: now, lastRun: lastRun?.date, enabledSince: enabledSince) else { return }
        run(.scheduled, at: now)
    }

    /// Re-reads the system, runs `scan` (with `cleans`, the shallow clean-up) and records the result.
    /// - Note: Ignored while a check is running — a scan takes longer than the 30-second due check, which would
    ///   otherwise start the same check again.
    func run(_ trigger: LoopRun.Trigger, at date: Date = .now) {
        guard !isChecking else { return }
        isChecking = true
        system.refreshAll()
        Task {
            let summary = await scan?()
            record(trigger, at: date, summary: summary)
            isChecking = false
        }
    }

    private func record(_ trigger: LoopRun.Trigger, at date: Date, summary: (count: Int, bytes: Int64)?) {
        history.insert(LoopRun(
            date: date,
            trigger: trigger,
            diskAvailable: system.disk?.available,
            memoryUsed: system.memory?.used,
            memoryPhysical: system.memory?.physical,
            pressure: system.memory?.pressure?.rawValue,
            readyCount: summary?.count ?? 0,
            readyBytes: summary?.bytes ?? 0,
            source: summary == nil ? .scanFailed : cleans ? .cleaned : .scan
        ), at: 0)
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
        save()
    }

    func clearHistory() {
        // The latest check still counts as done; otherwise clearing makes its scheduled time due again.
        if let last = lastRun?.date { enabledSince = max(enabledSince, last) }
        history = []
        save()
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
        }
        loginItemStatus = SMAppService.mainApp.status
    }

    private func save() {
        guard let defaults else { return }
        let encoder = JSONEncoder()
        defaults.set(enabled, forKey: Keys.enabled)
        defaults.set(try? encoder.encode(schedule), forKey: Keys.schedule)
        defaults.set(try? encoder.encode(history), forKey: Keys.history)
        defaults.set(enabledSince, forKey: Keys.enabledSince)
    }

    private enum Keys {
        static let enabled = "loop.enabled"
        static let schedule = "loop.schedule"
        static let history = "loop.history"
        static let enabledSince = "loop.enabledSince"
    }
}
