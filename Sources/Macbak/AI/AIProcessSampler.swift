import Darwin
import Foundation

/// What is read about one process: its name, executable path, and at most two arguments.
struct ProcessFacts: Sendable {
    var name: String
    var path: String
    /// The name the process gave itself.
    var argv0: String?
    /// For script runtimes such as node: the script it runs.
    var script: String?
}

/// A file name without its extension.
func stem(_ name: Substring) -> Substring {
    guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
    return name[..<dot]
}

/// Classifies processes with lookup tables built once from the catalog: one path split and a few dictionary lookups each.
/// - Important: Runs for every process (about 800) on every sample. Searching each path once per tool, and parsing
///   paths with `URL(fileURLWithPath:)` (which calls `lstat`), kept a fifth of a core busy.
struct AIProcessClassifier {
    /// Runtimes whose own name says nothing; the script they run names the tool.
    static let runtimes: Set<Substring> = ["node", "bun", "deno"]
    static let catalog = AIProcessClassifier(AITool.catalog)

    private let byBundle: [Substring: AITool]
    private let byName: [Substring: AITool]
    private let byInstallPath: [(fragment: String, tool: AITool)]

    init(_ tools: [AITool]) {
        var bundles: [Substring: AITool] = [:], names: [Substring: AITool] = [:]
        for tool in tools {
            for bundle in tool.process.bundles where bundles[Substring(bundle)] == nil { bundles[Substring(bundle)] = tool }
            for name in tool.process.names where names[Substring(name)] == nil { names[Substring(name)] = tool }
        }
        byBundle = bundles
        byName = names
        byInstallPath = tools.flatMap { tool in tool.process.installPaths.map { ($0, tool) } }
    }

    static func tool(for process: ProcessFacts, in classifier: AIProcessClassifier = catalog) -> AITool? {
        classifier.tool(for: process)
    }

    func tool(for process: ProcessFacts) -> AITool? {
        let parts = process.path.split(separator: "/")
        if let app = parts.lazy.compactMap({ byBundle[$0] }).first { return app }
        if let tool = byName[Substring(process.name)] ?? parts.last.flatMap({ byName[stem($0)] }) { return tool }
        let scriptParts = process.script?.split(separator: "/") ?? []
        if let tool = scriptParts.last.flatMap({ byName[stem($0)] }) { return tool }
        // Package installs live under node_modules; checking for it first skips the substring search for everything else.
        for (path, parts) in [(process.path, parts), (process.script ?? "", scriptParts)] where parts.contains("node_modules") {
            if let match = byInstallPath.first(where: { path.contains($0.fragment) }) { return match.tool }
        }
        return nil
    }
}

extension ProcessRule {
    func isSession(argv0: String?, parentIsSameTool: Bool) -> Bool {
        switch sessions {
        case .none: false
        case .argv0(let name): argv0 == name
        case .rootProcess: !parentIsSameTool
        }
    }

    var needsArgv0: Bool {
        if case .argv0 = sessions { true } else { false }
    }
}

/// Reads argv[0] and, for script runtimes, the first non-flag argument (the script path).
/// - Important: Nothing after the script is read; later arguments can hold secrets such as tokens.
enum ProcessArguments {
    static func read(_ pid: pid_t) -> (argv0: String?, script: String?) {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return (nil, nil) }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return (nil, nil) }
        return parse(buffer.prefix(size))
    }

    /// `KERN_PROCARGS2` layout: argc (Int32), executable path, NUL padding, then argc NUL-terminated arguments.
    static func parse(_ buffer: ArraySlice<UInt8>) -> (argv0: String?, script: String?) {
        let header = MemoryLayout<Int32>.size
        guard buffer.count > header else { return (nil, nil) }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var index = buffer.startIndex + header
        while index < buffer.endIndex && buffer[index] != 0 { index += 1 }
        while index < buffer.endIndex && buffer[index] == 0 { index += 1 }

        func nextArgument() -> String? {
            guard index < buffer.endIndex else { return nil }
            let start = index
            while index < buffer.endIndex && buffer[index] != 0 { index += 1 }
            defer { index += 1 }
            return String(decoding: buffer[start..<index], as: UTF8.self)
        }

        guard argc > 0, let argv0 = nextArgument() else { return (nil, nil) }
        guard AIProcessClassifier.runtimes.contains(argv0.split(separator: "/").last ?? "") else { return (argv0, nil) }
        var remaining = Int(argc) - 1
        while remaining > 0, let argument = nextArgument() {
            if !argument.hasPrefix("-") { return (argv0, argument) }
            remaining -= 1
        }
        return (argv0, nil)
    }
}

enum AIProcessSampler {
    struct Result: Sendable {
        let tools: [AIToolUsage]
        let cpuTimes: [pid_t: UInt64]
        let time: UInt64
        /// Ids of every tool seen running, including processes whose usage could not be read.
        let running: Set<String>
        /// The process list was read in full. When false, `running` may be missing tools.
        let complete: Bool
    }

    private struct Hit {
        let tool: AITool
        let parent: pid_t
        let argv0: String?
        let memory: UInt64
        let cpu: Double
    }

    /// CPU percent comes from the change in each process's CPU time between two samples.
    /// - Note: `ri_user_time`/`ri_system_time` and `mach_absolute_time()` are both in mach ticks, so the ratio needs no timebase.
    static func sample(previous: [pid_t: UInt64], previousTime: UInt64, classifier: AIProcessClassifier = .catalog) -> Result {
        let now = mach_absolute_time()
        let elapsed = previousTime > 0 ? Double(now - previousTime) : 0

        var pids = [pid_t](repeating: 0, count: 8192)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        // A failed or full list may have left tools out, and "not seen" must not read as "not running".
        var complete = count > 0 && count < pids.count
        let me = getuid()
        var hits: [pid_t: Hit] = [:]
        var times: [pid_t: UInt64] = [:]
        var running: Set<String> = []

        for pid in pids.prefix(max(count, 0)) where pid > 0 {
            var facts = ProcessFacts(name: name(of: pid), path: path(of: pid))
            // AI tools run as this user. A live process of ours that cannot be identified could be one of them; other
            // users' processes, and ones that ended since the list was read, cannot.
            if facts.path.isEmpty, owner(of: pid) == me { complete = false }
            var tool = classifier.tool(for: facts)
            if tool == nil, AIProcessClassifier.runtimes.contains(Substring(facts.name)) {
                (facts.argv0, facts.script) = ProcessArguments.read(pid)
                tool = classifier.tool(for: facts)
            }
            guard let tool else { continue }
            // Running even when its usage cannot be read: dropping it here once let its cache count as unused.
            running.insert(tool.id)
            if tool.process.needsArgv0, facts.argv0 == nil { facts.argv0 = ProcessArguments.read(pid).argv0 }
            guard let usage = resourceUsage(of: pid) else { continue }

            let cpuTime = usage.ri_user_time + usage.ri_system_time
            times[pid] = cpuTime
            var cpu = 0.0
            if elapsed > 0, let before = previous[pid], cpuTime >= before { cpu = Double(cpuTime - before) / elapsed * 100 }
            hits[pid] = Hit(tool: tool, parent: parent(of: pid), argv0: facts.argv0, memory: usage.ri_phys_footprint, cpu: cpu)
        }

        var usage: [AITool: AIToolUsage] = [:]
        for hit in hits.values {
            var entry = usage[hit.tool] ?? AIToolUsage(tool: hit.tool)
            entry.processes += 1
            entry.memory += hit.memory
            entry.cpu += hit.cpu
            if hit.tool.process.isSession(argv0: hit.argv0, parentIsSameTool: hits[hit.parent]?.tool == hit.tool) { entry.sessions += 1 }
            usage[hit.tool] = entry
        }
        return Result(tools: Array(usage.values), cpuTimes: times, time: now, running: running, complete: complete)
    }

    private static func name(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 64)
        proc_name(pid, &buffer, 64)
        return string(from: buffer)
    }

    private static func path(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        proc_pidpath(pid, &buffer, 4096)
        return string(from: buffer)
    }

    /// The process's user id, or nil when it has ended or cannot be read.
    private static func owner(of pid: pid_t) -> uid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info.pbi_uid : nil
    }

    private static func parent(of pid: pid_t) -> pid_t {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? pid_t(info.pbi_ppid) : 0
    }

    private static func resourceUsage(of pid: pid_t) -> rusage_info_v4? {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return status == 0 ? info : nil
    }

    private static func string(from buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
