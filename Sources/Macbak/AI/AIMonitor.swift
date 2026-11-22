import Darwin
import Foundation
import Observation

struct AIToolUsage: Identifiable, Equatable, Sendable {
    var id: String { tool.id }
    let tool: AITool
    var processes = 0
    var sessions = 0
    /// Percent of one CPU core, summed over the tool's processes.
    var cpu = 0.0
    var memory: UInt64 = 0
}

struct AIActivitySample: Identifiable, Equatable, Sendable {
    let id: Int
    /// CPU percent by tool id; tools not running are absent.
    let cpuByTool: [String: Double]
    let memory: UInt64

    var cpu: Double { cpuByTool.values.reduce(0, +) }

    func cpu(of vendor: AIVendor) -> Double {
        cpuByTool.reduce(0) { sum, entry in AITool.with(id: entry.key)?.vendor == vendor ? sum + entry.value : sum }
    }
}

/// Reads AI process usage every 2 seconds and session metadata every 30 seconds, all off the main actor.
/// - Important: Samples only while the window or the menu bar panel is on screen: nothing else shows this data, and
///   scanning about 800 processes every 2 seconds is the app's largest steady cost. Otherwise it pauses.
@MainActor
@Observable
final class AIMonitor {
    static let historyCapacity = 60

    /// Running tools, most memory first.
    private(set) var tools: [AIToolUsage] = []
    private(set) var history: [AIActivitySample] = []
    private(set) var activity: AIActivity?
    private(set) var processSampledAt: Date?
    private(set) var activitySampledAt: Date?
    let interval: Duration
    private let isWindowShown: @MainActor () -> Bool

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var cpuTimes: [pid_t: UInt64] = [:]
    @ObservationIgnored private var lastSampleTime: UInt64 = 0
    @ObservationIgnored private var tick = 0
    @ObservationIgnored private var paused = false
    @ObservationIgnored private var lastRunning: Set<String> = []
    @ObservationIgnored private var lastSampleComplete = false

    init(interval: Duration = .seconds(2), isWindowShown: @escaping @MainActor () -> Bool = { true }) {
        self.interval = interval
        self.isWindowShown = isWindowShown
    }

    var totalCPU: Double { tools.reduce(0) { $0 + $1.cpu } }
    var totalMemory: UInt64 { tools.reduce(0) { $0 + $1.memory } }
    var totalSessions: Int { tools.reduce(0) { $0 + $1.sessions } }

    /// Ids of running tools from a complete sample under ten seconds old, or nil — then nothing may count as unused.
    var runningToolIDs: Set<String>? {
        guard let sampledAt = processSampledAt, lastSampleComplete, Date.now.timeIntervalSince(sampledAt) < 10 else { return nil }
        return lastRunning
    }

    func usage(of tool: AITool) -> AIToolUsage? { tools.first { $0.tool == tool } }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.sample()
                try? await Task.sleep(for: self.interval)
            }
        }
    }

    /// Samples now rather than at the next tick, for a view that has just come on screen with nothing to show.
    func wake() async {
        guard processSampledAt == nil else { return }
        await sample()
    }

    private func sample() async {
        guard isWindowShown() else { return pause() }
        paused = false
        await sampleProcesses()
        if tick % 15 == 0 { await sampleActivity() }
        tick += 1
    }

    /// Drops the values as soon as nothing watches, so a stale "not running" can never mark a cache unused and a
    /// view coming back never shows old numbers as current.
    private func pause() {
        guard !paused else { return }
        paused = true
        tools = []
        history = []
        processSampledAt = nil
        lastRunning = []
        lastSampleComplete = false
        cpuTimes = [:]
        lastSampleTime = 0
        tick = 0
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func sampleProcesses() async {
        let previous = cpuTimes
        let previousTime = lastSampleTime
        let result = await Task.detached(priority: .utility) { AIProcessSampler.sample(previous: previous, previousTime: previousTime) }.value
        cpuTimes = result.cpuTimes
        lastSampleTime = result.time
        tools = result.tools.sorted { $0.memory > $1.memory }
        lastRunning = result.running
        lastSampleComplete = result.complete
        processSampledAt = .now
        let cpuByTool = Dictionary(uniqueKeysWithValues: tools.map { ($0.tool.id, $0.cpu) })
        history.append(AIActivitySample(id: (history.last?.id ?? -1) + 1, cpuByTool: cpuByTool, memory: totalMemory))
        if history.count > Self.historyCapacity { history.removeFirst(history.count - Self.historyCapacity) }
    }

    private func sampleActivity() async {
        activity = await Task.detached(priority: .utility) { AIActivityReader.read() }.value
        activitySampledAt = .now
    }
}
