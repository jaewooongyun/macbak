import Darwin
import Foundation

/// A booted simulator, the memory its processes hold, and whether anything is using it.
struct BootedSimulator: Identifiable, Sendable {
    let udid: String
    let name: String
    /// The device set folder (`…/Devices`) that `simctl --set` takes.
    let setPath: String
    /// Footprint of every process it runs; a lower bound when some could not be read.
    let memory: UInt64
    /// The later of its boot and its newest app launch.
    let lastActivity: Date
    /// Why it counts as in use, or nil when nothing is using it.
    let busy: String?

    var id: String { udid }
    var isIdle: Bool { busy == nil }
}

/// Memory held by simulators nobody is using. Apps a person runs (Xcode, Slack, Finder…) are never offered: they are in use.
/// - Important: Use is told without reading process arguments, which can carry secrets: a simulator is in use when an app
///   inside it was started by a debugger or test runner (its parent is not the simulator's own `launchd_sim`), when a
///   process outside it holds files in its device folder, or when it booted or launched an app within the last hour —
///   other sessions run tests and debug on simulators all day, and switching one off under them breaks their work.
enum SimulatorMemory {
    static let activeWithin: TimeInterval = 3600
    /// Simulator services that hold device files themselves; their open files say nothing about use.
    static let services: Set<String> = [
        "DeviceFS", "CoreSimulatorService", "com.apple.CoreSimulator.CoreSimulatorService", "SimRenderServer", "simdiskimaged",
        "SimLaunchHost", "SimStreamProcessorService", "launchd_sim", "Macbak",
    ]

    struct ProcessInfo: Sendable {
        let pid: pid_t
        let ppid: pid_t
        let path: String
        let start: Date
        /// nil when it could not be read.
        let memory: UInt64?

        var name: String { (path as NSString).lastPathComponent }
    }

    struct OpenFile: Sendable {
        let pid: pid_t
        let path: String
    }

    /// The booted simulators, idle ones first; nil when the process list or `lsof` could not be read, so none is offered.
    static func read(now: Date = .now) -> [BootedSimulator]? {
        guard let table = processTable() else { return nil }
        // Nothing booted: skip the system-wide `lsof` and `simctl`, by far the slowest part.
        guard table.values.contains(where: { $0.path.hasSuffix("/launchd_sim") }) else { return [] }
        guard let files = openDeviceFiles() else { return nil }
        let names = SimulatorList.read().map { devices in
            Dictionary(devices.map { ($0.udid, "\($0.name) (\($0.runtime))") }, uniquingKeysWith: { first, _ in first })
        } ?? [:]
        return judge(table, files: files, names: names, now: now)
    }

    static func judge(_ table: [pid_t: ProcessInfo], files: [OpenFile], names: [String: String], now: Date) -> [BootedSimulator] {
        let roots = Set(table.values.filter { $0.path.hasSuffix("/launchd_sim") }.map(\.pid))
        var rootOf: [pid_t: pid_t] = [:]
        for pid in table.keys {
            var current = pid
            for _ in 0..<64 {
                if roots.contains(current) { rootOf[pid] = current; break }
                guard let up = table[current]?.ppid, up > 1 else { break }
                current = up
            }
        }

        var found: [BootedSimulator] = []
        for root in roots {
            let tree = Set(rootOf.filter { $0.value == root }.map(\.key))
            // Which device it runs: a folder its own processes hold files in.
            guard let device = files.lazy.filter({ tree.contains($0.pid) }).compactMap({ deviceFolder(in: $0.path) }).first else { continue }
            let marker = device.folder + "/"
            let apps = table.values.filter { $0.path.hasPrefix(marker + "data/Containers/Bundle/") }
            let launchedElsewhere = apps.filter { !tree.contains($0.pid) }
            // A process whose details could not be read is not known to be harmless, so it still counts.
            let outsideOpeners = Set(files.filter { $0.path.hasPrefix(marker) && !tree.contains($0.pid) }.map { table[$0.pid]?.name ?? "알 수 없는 프로세스" })
                .subtracting(services)
            let boot = table[root]?.start ?? .distantPast
            let last = apps.map(\.start).reduce(boot, max)

            var busy: String?
            if !launchedElsewhere.isEmpty {
                busy = "디버거나 테스트가 실행한 앱이 있음"
            } else if let opener = outsideOpeners.sorted().first {
                busy = "\(opener)가 쓰는 중"
            } else if now.timeIntervalSince(last) < activeWithin {
                busy = "최근 1시간 안에 쓰임"
            }
            let memory = tree.compactMap { table[$0]?.memory }.reduce(0, +) + launchedElsewhere.compactMap(\.memory).reduce(0, +)
            found.append(BootedSimulator(udid: device.udid, name: names[device.udid] ?? "시뮬레이터 \(device.udid.prefix(8))",
                                         setPath: device.set, memory: memory, lastActivity: last, busy: busy))
        }
        return found.sorted { ($0.isIdle ? 0 : 1, $0.lastActivity) < ($1.isIdle ? 0 : 1, $1.lastActivity) }
    }

    /// "…/Devices/<UDID>/data/x" → the UDID, "…/Devices/<UDID>" and "…/Devices".
    static func deviceFolder(in path: String) -> (udid: String, folder: String, set: String)? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard let index = parts.firstIndex(of: "Devices"), index + 1 < parts.count else { return nil }
        let udid = String(parts[index + 1])
        guard udid.count == 36, udid.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { return nil }
        let set = parts[...index].joined(separator: "/")
        return (udid, set + "/" + udid, set)
    }

    /// Switches it off with `simctl shutdown` — the device and its data stay; only what was running is gone.
    static func shutdown(_ simulator: BootedSimulator) -> Bool {
        Command.run("/usr/bin/xcrun", ["simctl", "--set", simulator.setPath, "shutdown", simulator.udid], timeout: .seconds(90))?.status == 0
    }

    private static func processTable() -> [pid_t: ProcessInfo]? {
        var pids = [pid_t](repeating: 0, count: 8192)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        guard count > 0, count < pids.count else { return nil }
        var table: [pid_t: ProcessInfo] = [:]
        for pid in pids.prefix(count) where pid > 0 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { continue }
            var buffer = [CChar](repeating: 0, count: 4096)
            proc_pidpath(pid, &buffer, 4096)
            var usage = rusage_info_v4()
            let read = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            table[pid] = ProcessInfo(pid: pid, ppid: pid_t(info.pbi_ppid),
                                     path: String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self),
                                     start: Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)),
                                     memory: read == 0 ? usage.ri_phys_footprint : nil)
        }
        return table
    }

    /// Files open under any simulator device folder, with the process holding each; nil when `lsof` failed.
    private static func openDeviceFiles() -> [OpenFile]? {
        guard let output = Command.run("/usr/sbin/lsof", ["-n", "-Fpn"], timeout: .seconds(15)), output.status == 0 else { return nil }
        let lines = String(decoding: output.stdout, as: UTF8.self).split(separator: "\n")
        guard lines.count >= OpenFiles.minimumLines else { return nil }
        var files: [OpenFile] = []
        var pid: pid_t = 0
        for line in lines {
            if line.hasPrefix("p") {
                pid = pid_t(line.dropFirst()) ?? 0
            } else if line.hasPrefix("n/"), line.contains("/Devices/") {
                files.append(OpenFile(pid: pid, path: String(line.dropFirst())))
            }
        }
        return files
    }
}

extension BootedSimulator {
    var runStep: RunStep { RunStep(id: udid, name: name, icon: .symbol("ipad.and.iphone"), amount: Double(memory), amountText: memory.memoryText) }

    /// "쓰지 않음 · 마지막 사용 15시간 전", or why it is in use.
    var detail: String {
        let hours = Int(Date.now.timeIntervalSince(lastActivity) / 3600)
        let ago = hours < 1 ? "1시간 안" : hours < 48 ? "\(hours)시간 전" : "\(hours / 24)일 전"
        return (busy ?? "쓰지 않음") + " · 마지막 사용 " + ago
    }
}

/// Switches simulators off one by one, checking each again first, and reports the memory change measured around it.
@MainActor
enum SimulatorShutdown {
    /// Switches them off and reports the memory change measured around it.
    static func run(_ simulators: [BootedSimulator], progress: (String, String?) -> Void) async -> String {
        let before = SystemReader.memory()?.used
        let off = await switchOff(simulators, progress: progress)
        // Memory is handed back over a few seconds.
        try? await Task.sleep(for: .seconds(3))
        let after = SystemReader.memory()?.used
        var text = "\(off)대 끔"
        if let before, let after, before > after { text += " · 메모리 사용 \((before - after).memoryText) 줄어듦 (전후 측정)" }
        return text
    }

    /// - Parameter progress: called per simulator with nil when it went off, or the reason it was left on.
    /// - Returns: how many went off.
    static func switchOff(_ simulators: [BootedSimulator], progress: (String, String?) -> Void) async -> Int {
        var off = 0
        for simulator in simulators {
            // Asked again right before: a session may have started using it while the confirmation was open.
            let now = await Task.detached(priority: .userInitiated) { SimulatorMemory.read() }.value
            guard let current = now?.first(where: { $0.udid == simulator.udid }) else {
                progress(simulator.udid, now == nil ? "사용 여부를 확인하지 못했습니다" : "이미 꺼져 있습니다")
                continue
            }
            if let busy = current.busy {
                progress(simulator.udid, busy)
                continue
            }
            let done = await Task.detached(priority: .userInitiated) { SimulatorMemory.shutdown(current) }.value
            if done { off += 1 }
            progress(simulator.udid, done ? nil : "simctl shutdown 실패")
        }
        return off
    }
}
