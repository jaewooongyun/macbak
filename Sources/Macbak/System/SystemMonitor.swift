import AppKit
import Darwin
import IOKit
import Observation

struct DiskUsage: Equatable {
    var name: String
    var total: Int64
    /// What Finder reports as available: free space plus what macOS can purge on demand.
    var available: Int64
    /// Free right now, without purging anything.
    var availableNow: Int64

    var used: Int64 { max(total - available, 0) }
    var purgeable: Int64 { max(available - availableNow, 0) }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

/// `kern.memorystatus_vm_pressure_level` values.
enum MemoryPressure: Int32 {
    case normal = 1, warning = 2, critical = 4
}

/// Memory split the way Activity Monitor labels it.
/// - Note: An approximation from `host_statistics64`; Activity Monitor's exact formula is not public.
struct MemoryUsage: Equatable {
    var physical: UInt64
    var app: UInt64
    var wired: UInt64
    var compressed: UInt64
    var cached: UInt64
    var free: UInt64
    var swapUsed: UInt64
    var swapTotal: UInt64
    var pressure: MemoryPressure?
    /// Memory pressure as a share, 0...1: 100 − `kern.memorystatus_level` (the percent macOS counts as available).
    /// Moves continuously, like Activity Monitor's pressure graph, while `pressure` only changes between three levels.
    var pressureShare: Double?

    var used: UInt64 { app + wired + compressed }
    var other: UInt64 {
        let accounted = used + cached + free
        return physical > accounted ? physical - accounted : 0
    }
    var usedFraction: Double { physical > 0 ? min(Double(used) / Double(physical), 1) : 0 }
}

struct MemorySample: Identifiable, Equatable {
    let id: Int
    let used: UInt64
}

/// The three resources that make a Mac work hard, each 0...1 for one sample. The busiest one sets the pulse.
struct VitalSample: Identifiable, Equatable {
    enum Vital: CaseIterable {
        case cpu, gpu, memory

        var title: String {
            switch self {
            case .cpu: "CPU"
            case .gpu: "GPU"
            case .memory: "메모리 압력"
            }
        }
    }

    let id: Int
    /// Share of all cores busy since the previous sample.
    let cpu: Double
    /// The GPU's own utilization; nil when the driver reports none.
    let gpu: Double?
    /// Memory pressure as a share (see `MemoryUsage.pressureShare`), shown as is.
    let memory: Double?
    /// macOS's own pressure level, which sets how much `memory` counts toward the pulse.
    var memoryLevel: MemoryPressure? = nil

    /// The value shown on each meter.
    func value(of vital: Vital) -> Double? {
        switch vital {
        case .cpu: cpu
        case .gpu: gpu
        case .memory: memory
        }
    }

    /// How much each vital counts toward the pulse. Memory counts half while macOS calls its pressure normal — a Mac fills
    /// its memory on purpose, and counting it fully kept an idle Mac "busy" — and at least 0.6 or 0.95 once it warns.
    func contribution(of vital: Vital) -> Double? {
        guard vital == .memory, let memory else { return value(of: vital) }
        switch memoryLevel {
        case .warning: return max(memory, 0.6)
        case .critical: return max(memory, 0.95)
        case .normal, nil: return memory * 0.5
        }
    }

    var load: Double { Vital.allCases.compactMap(contribution(of:)).max() ?? 0 }
    var leader: Vital { Vital.allCases.max { (contribution(of: $0) ?? -1) < (contribution(of: $1) ?? -1) } ?? .cpu }
}

/// Cumulative CPU ticks of all cores. The counters are 32-bit and wrap, so differences use wrapping subtraction.
struct CPUTicks: Equatable {
    let busy: UInt32
    let idle: UInt32

    func load(since earlier: CPUTicks) -> Double {
        let busy = Double(self.busy &- earlier.busy)
        let idle = Double(self.idle &- earlier.idle)
        return busy + idle > 0 ? busy / (busy + idle) : 0
    }
}

extension AppMemory {
    /// "1.2 GB", or "–" when the memory could not be read.
    /// With its helpers; "–" when its own memory could not be read, since the helpers alone would understate it.
    var totalText: String { footprint > 0 ? total.memoryText : "–" }
}

struct AppMemory: Identifiable {
    let id: pid_t
    let name: String
    let icon: NSImage?
    let footprint: UInt64
    /// With the launch date, tells this app apart from a later process that reuses its pid.
    var bundleID: String?
    var launched: Date?
    var isHidden = false
    /// In front right now.
    var isActive = false
    /// Normal windows, minimized and on other Spaces included; nil when the window list could not be read.
    var windows: Int?
    /// The processes it is responsible for besides its own, and their memory; empty and 0 until the memory screen measures.
    var helperPIDs: Set<pid_t> = []
    var helpers: UInt64 = 0
    /// Its own pid and its helpers'.
    var members: Set<pid_t> { helperPIDs.union([id]) }

    var total: UInt64 { footprint + helpers }
}

/// Read-only system queries. Nothing here writes, deletes, or needs extra permission.
enum SystemReader {
    private static let host = mach_host_self()

    static func disk(at path: String = "/") -> DiskUsage? {
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return DiskUsage(
            name: values.volumeName ?? "Macintosh HD",
            total: Int64(total),
            available: available,
            availableNow: Int64(values.volumeAvailableCapacity ?? Int(available))
        )
    }

    static func memory() -> MemoryUsage? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = UInt64(getpagesize())
        let purgeable = UInt64(stats.purgeable_count)
        let anonymous = UInt64(stats.internal_page_count)

        var level: Int32 = 0
        var levelSize = MemoryLayout<Int32>.size
        let pressure = sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0) == 0 ? MemoryPressure(rawValue: level) : nil
        var available: Int32 = 0
        var availableSize = MemoryLayout<Int32>.size
        let pressureShare = sysctlbyname("kern.memorystatus_level", &available, &availableSize, nil, 0) == 0
            ? min(max(1 - Double(available) / 100, 0), 1) : nil

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let hasSwap = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0

        return MemoryUsage(
            physical: ProcessInfo.processInfo.physicalMemory,
            app: (anonymous > purgeable ? anonymous - purgeable : 0) * page,
            wired: UInt64(stats.wire_count) * page,
            compressed: UInt64(stats.compressor_page_count) * page,
            cached: (UInt64(stats.external_page_count) + purgeable) * page,
            free: (UInt64(stats.free_count) + UInt64(stats.speculative_count)) * page,
            swapUsed: hasSwap ? swap.xsu_used : 0,
            swapTotal: hasSwap ? swap.xsu_total : 0,
            pressure: pressure,
            pressureShare: pressureShare
        )
    }

    static func cpuTicks() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        let (user, system, idle, nice) = info.cpu_ticks
        return CPUTicks(busy: user &+ system &+ nice, idle: idle)
    }

    /// The busiest GPU's utilization, from the driver's statistics in the I/O Registry (no extra permission needed).
    static func gpuUtilization() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var busiest: Double?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any],
                  let percent = stats["Device Utilization %"] as? Int else { continue }
            busiest = max(busiest ?? 0, min(Double(percent) / 100, 1))
        }
        return busiest
    }

    /// Footprint of each regular app's main process. Helper processes (browser tabs, renderers) are not added in.
    /// Every regular app with its main process's memory, heaviest first.
    /// - Important: An app whose memory cannot be read (some of Apple's own, such as Preview) stays in the list with a
    ///   footprint of 0, shown as "–", rather than vanishing from the list.
    @MainActor static func runningApps() -> [AppMemory] {
        let windows = windowCounts()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map { app -> AppMemory in
                var info = rusage_info_v4()
                let result = withUnsafeMutablePointer(to: &info) {
                    $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(app.processIdentifier, RUSAGE_INFO_V4, $0) }
                }
                return AppMemory(id: app.processIdentifier, name: app.localizedName ?? "앱", icon: app.icon,
                                 footprint: result == 0 ? info.ri_phys_footprint : 0,
                                 bundleID: app.bundleIdentifier, launched: app.launchDate, isHidden: app.isHidden, isActive: app.isActive,
                                 windows: windows.map { $0[app.processIdentifier] ?? 0 })
            }
            .sorted { $0.footprint > $1.footprint }
    }

    /// Normal windows (layer 0, at least 100x100) per process, minimized and other Spaces included. Owners and sizes
    /// need no screen-recording permission. Apps that keep hidden windows count as having windows, which only ever
    /// keeps an app off the "no window" list.
    static func windowCounts() -> [pid_t: Int]? {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        var counts: [pid_t: Int] = [:]
        for window in list {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let bounds = window[kCGWindowBounds as String] as? [String: Double],
                  (bounds["Width"] ?? 0) >= 100, (bounds["Height"] ?? 0) >= 100 else { continue }
            counts[pid, default: 0] += 1
        }
        return counts
    }

}

@MainActor
@Observable
final class SystemMonitor {
    static let historyCapacity = 60

    private(set) var disk: DiskUsage?
    private(set) var memory: MemoryUsage?
    private(set) var history: [MemorySample] = []
    /// The heaviest apps, for showing where memory goes.
    private(set) var apps: [AppMemory] = []
    /// Every regular app, for finding the ones not in use.
    private(set) var running: [AppMemory] = []
    /// Set by the memory screen while it is shown; only then is every process read (helpers, orphans, idle sessions).
    @ObservationIgnored var memoryScreenShown = false
    private(set) var ownership: ProcessOwnership.State = .off
    /// The latest full process read, while the memory screen is shown.
    private(set) var processes: ProcessSnapshot?
    /// Developer tools left running with no owner, while the memory screen is shown.
    private(set) var orphans: [OrphanProcess] = []
    /// Claude sessions idle past the Settings age, while the memory screen is shown.
    private(set) var idleSessions: [IdleSession] = []
    /// Virtual machines and emulators running, largest first, while the memory screen is shown.
    private(set) var machines: [DevMachine] = []
    /// The Settings age past which an idle AI session is offered.
    var sessionIdleAge: TimeInterval { ages().seconds(.aiSessionIdle) }
    @ObservationIgnored private let ages: @MainActor () -> CleanupAges
    @ObservationIgnored private let processSources: ProcessSources
    /// CPU, GPU and memory per sample, oldest first; empty until two CPU readings exist.
    private(set) var vitals: [VitalSample] = []
    let cores = ProcessInfo.processInfo.activeProcessorCount
    let interval: Duration
    private let isWindowShown: @MainActor () -> Bool

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var tick = 0
    @ObservationIgnored private var lastTicks = SystemReader.cpuTicks()
    /// When each app last came to the front, by pid. macOS keeps no such record, so it starts when this app does.
    @ObservationIgnored private(set) var lastActive: [pid_t: Date] = [:]
    let trackingSince = Date.now
    @ObservationIgnored private var activationObserver: NSObjectProtocol?

    /// What the memory screen reads about every process; tests replace it to count reads or feed a table.
    struct ProcessSources: Sendable {
        var snapshot: @Sendable () -> ProcessSnapshot? = { ProcessSnapshot.capture() }
        var responsible: ProcessOwnership.Responsible? = ProcessOwnership.live
        var services: @Sendable () -> Set<pid_t>? = { OrphanProcesses.servicePIDs() }
        var sessions: @Sendable () -> [AISessions.Record]? = { AISessions.readLive() }
        var jobStates: @Sendable ([String]) -> [String: String] = { AISessions.jobStatesLive($0) }

        /// One full read the way the memory screen reads it: helpers' owners, orphaned tools and idle sessions.
        struct Reading: Sendable {
            var snapshot: ProcessSnapshot?
            var owners: ProcessOwnership.Owners?
            var orphans: [OrphanProcess] = []
            /// nil when the sessions folder could not be read.
            var sessions: [IdleSession]?
            var machines: [DevMachine] = []
        }

        /// - Parameters:
        ///   - previous: the reading before, for helpers' activity; idle sessions need one five seconds or more earlier.
        ///   - apps: every running application's pid and bundle folder, read on the main actor.
        func read(previous: ProcessSnapshot?, apps: [pid_t: String?], idleAge: TimeInterval) -> Reading {
            guard let snapshot = snapshot() else { return Reading() }
            let records = sessions()
            let sessions = records.flatMap { records in
                AISessions.store.map { store in
                    AISessions.candidates(.init(records: records, snapshot: snapshot, previous: previous, jobStates: jobStates(records.compactMap(\.jobId)),
                                                store: store, idleAge: idleAge, now: .now, names: AISessions.names))
                }
            }
            let owners = responsible.map { ProcessOwnership.owners(snapshot, responsible: $0) }
            return Reading(snapshot: snapshot, owners: owners,
                           orphans: OrphanProcesses.candidates(.init(snapshot: snapshot, services: services(), apps: apps, home: NSHomeDirectory(), now: .now)),
                           sessions: sessions, machines: DevMachines.find(snapshot, owners: owners?.owner, apps: apps))
        }
    }

    /// - Parameter isWindowShown: the app list feeds only the window, so it is not read while the window is off screen.
    /// - Parameter ages: the Settings ages, read on each refresh.
    init(interval: Duration = .seconds(2), isWindowShown: @escaping @MainActor () -> Bool = { true }, processes: ProcessSources = ProcessSources(),
         ages: @escaping @MainActor () -> CleanupAges = { CleanupAges() }) {
        self.interval = interval
        self.isWindowShown = isWindowShown
        processSources = processes
        self.ages = ages
        if let front = NSWorkspace.shared.frontmostApplication { lastActive[front.processIdentifier] = .now }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier else { return }
            MainActor.assumeIsolated { self?.lastActive[pid] = .now }
        }
        refreshAll()
    }

    func start() {
        guard task == nil else { return }
        let interval = self.interval
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                self.poll()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Running apps that look unused, for a person to choose from in the window.
    var idleApps: [IdleApp] {
        IdleApps.candidates(running, lastActive: lastActive, trackingSince: trackingSince, now: .now)
    }

    func refreshAll() {
        refreshDisk()
        refreshApps()
        sampleMemory()
    }

    private func refreshApps() {
        let fresh = SystemReader.runningApps()
        // Only processes that are gone lose their record; a reused pid is told apart by launch date in `IdleApps`.
        lastActive = lastActive.filter { NSRunningApplication(processIdentifier: $0.key) != nil }
        // While the memory screen is shown the list waits for the helpers, so rows do not jump from own to total memory.
        if memoryScreenShown { Task { await refreshProcesses(fresh) } } else { show(fresh) }
    }

    /// Reads every process off the main actor and adds each app's helpers; reads nothing while the memory screen is not shown.
    /// - Parameter fresh: the apps just read; nil reads them again.
    func refreshProcesses(_ fresh: [AppMemory]? = nil) async {
        guard memoryScreenShown else { return }
        let sources = processSources
        let running = OrphanProcesses.runningApps()
        // Helpers' activity is measured against the reading before, ten seconds earlier.
        let previous = processes
        let idleAge = sessionIdleAge
        let reading = await Task.detached(priority: .utility) { sources.read(previous: previous, apps: running, idleAge: idleAge) }.value
        let fresh = fresh ?? SystemReader.runningApps()
        guard memoryScreenShown else { return show(fresh) }
        let (summed, state) = ProcessOwnership.apply(fresh, snapshot: reading.snapshot, owners: reading.owners)
        show(summed)
        ownership = state
        processes = reading.snapshot
        orphans = reading.orphans
        idleSessions = reading.sessions ?? []
        machines = reading.machines
    }

    private func show(_ fresh: [AppMemory]) {
        running = fresh
        apps = Array(fresh.prefix(6))
        if !memoryScreenShown {
            ownership = .off
            processes = nil
            orphans = []
            idleSessions = []
            machines = []
        }
    }

    var historySpanText: String {
        let seconds = Int((interval * Self.historyCapacity).components.seconds)
        return seconds >= 60 ? "최근 \(seconds / 60)분" : "최근 \(seconds)초"
    }

    private func poll() {
        tick += 1
        sampleMemory()
        sampleVitals()
        // The app list re-sorts on refresh; a slower cadence keeps rows from jumping around.
        if tick % 5 == 0, isWindowShown() { refreshApps() }
        if tick % 30 == 0 { refreshDisk() }
    }

    /// Volume capacity queries can take a tenth of a second, so they run off the main actor.
    private func refreshDisk() {
        Task { [weak self] in
            let disk = await Task.detached(priority: .utility) { SystemReader.disk() }.value
            self?.disk = disk
        }
    }

    private func sampleVitals() {
        guard let ticks = SystemReader.cpuTicks() else { return }
        defer { lastTicks = ticks }
        guard let earlier = lastTicks else { return }
        vitals.append(VitalSample(id: (vitals.last?.id ?? -1) + 1, cpu: ticks.load(since: earlier),
                                  gpu: SystemReader.gpuUtilization(), memory: memory?.pressureShare, memoryLevel: memory?.pressure))
        if vitals.count > Self.historyCapacity { vitals.removeFirst(vitals.count - Self.historyCapacity) }
    }

    private func sampleMemory() {
        guard let usage = SystemReader.memory() else { return }
        memory = usage
        history.append(MemorySample(id: (history.last?.id ?? -1) + 1, used: usage.used))
        if history.count > Self.historyCapacity {
            history.removeFirst(history.count - Self.historyCapacity)
        }
    }
}
