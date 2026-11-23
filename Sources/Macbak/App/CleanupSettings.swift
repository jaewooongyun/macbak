import Foundation
import Observation

/// How long each kind of item must sit untouched before a clean-up may take it. The defaults are the rules' standing
/// values; every choice is at least a day, since a shorter wait would offer things still in use.
/// - Important: The scheduled loop and the menu bar's immediate clean-up read the same values, so a shorter choice widens
///   what goes without anyone picking it. Open files and running apps protect an item whatever the age.
struct CleanupAges: Equatable, Sendable {
    enum Item: String, CaseIterable, Sendable {
        case buildCache, appCache, general, logs, deviceSupportProtect, deviceSupportShallow, simulatorQuiet
        case aiChatLogs, aiJobScratch, nodeModules

        var title: String {
            switch self {
            case .buildCache: "Xcode 빌드 캐시"
            case .appCache: "앱 캐시"
            case .general: "개발 도구·기타 캐시"
            case .logs: "로그"
            case .deviceSupportProtect: "기기 지원 파일 보호"
            case .deviceSupportShallow: "기기 지원 파일 자동 정리"
            case .simulatorQuiet: "시뮬레이터 미리 체크"
            case .aiChatLogs: "AI 대화 기록"
            case .aiJobScratch: "끝난 AI 작업 임시 파일"
            case .nodeModules: "오래 안 쓴 프로젝트의 node_modules"
            }
        }

        /// The values a person may pick, shortest first.
        var choices: [Int] {
            switch self {
            case .buildCache, .appCache, .general: [1, 2, 3, 5, 7, 14, 30]
            case .logs: [7, 14, 30, 60, 90]
            case .deviceSupportProtect: [1, 2, 3, 5, 7, 14]
            case .deviceSupportShallow: [7, 14, 30, 60]
            case .simulatorQuiet: [3, 5, 7, 14, 30]
            case .aiChatLogs: [30, 60, 90, 180, 365]
            case .aiJobScratch: [3, 7, 14, 30]
            case .nodeModules: [30, 60, 90, 180]
            }
        }

        /// Days, for every item.
        var unit: String { "일" }
        var key: String { "cleanup.age." + rawValue }
    }

    var buildCache = 1
    var appCache = 3
    var general = 3
    var logs = 30
    var deviceSupportProtect = 3
    var deviceSupportShallow = 14
    var simulatorQuiet = 5
    var aiChatLogs = 90
    var aiJobScratch = 7
    var nodeModules = 60

    subscript(item: Item) -> Int {
        get {
            switch item {
            case .buildCache: buildCache
            case .appCache: appCache
            case .general: general
            case .logs: logs
            case .deviceSupportProtect: deviceSupportProtect
            case .deviceSupportShallow: deviceSupportShallow
            case .simulatorQuiet: simulatorQuiet
            case .aiChatLogs: aiChatLogs
            case .aiJobScratch: aiJobScratch
            case .nodeModules: nodeModules
            }
        }
        set {
            switch item {
            case .buildCache: buildCache = newValue
            case .appCache: appCache = newValue
            case .general: general = newValue
            case .logs: logs = newValue
            case .deviceSupportProtect: deviceSupportProtect = newValue
            case .deviceSupportShallow: deviceSupportShallow = newValue
            case .simulatorQuiet: simulatorQuiet = newValue
            case .aiChatLogs: aiChatLogs = newValue
            case .aiJobScratch: aiJobScratch = newValue
            case .nodeModules: nodeModules = newValue
            }
        }
    }

    /// The item's wait in seconds.
    func seconds(_ item: Item) -> TimeInterval { TimeInterval(self[item]) * 86_400 }

    /// Saved values, each taken only if it is one of its item's choices; anything else, or nothing saved, is the default.
    /// Automatic clean-up of device support never comes before its protection ends.
    init(defaults: UserDefaults?) {
        for item in Item.allCases {
            if let saved = defaults?.object(forKey: item.key) as? Int, item.choices.contains(saved) { self[item] = saved }
        }
        self = normalized()
    }

    init() {}

    func normalized() -> CleanupAges {
        var ages = self
        ages.deviceSupportShallow = max(ages.deviceSupportShallow, ages.deviceSupportProtect)
        return ages
    }
}

/// The clean-up ages the person picked in Settings. Scans take a snapshot when they start; rows carry it, and the executor
/// refuses a row whose snapshot no longer matches.
@MainActor
@Observable
final class CleanupSettings {
    private(set) var ages: CleanupAges

    @ObservationIgnored private let defaults: UserDefaults?

    /// - Parameter defaults: `nil` keeps everything in memory (used by `--snapshot`). Creating one only reads.
    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        ages = CleanupAges(defaults: defaults)
    }

    /// Takes `value` only if it is one of the item's choices.
    func set(_ item: CleanupAges.Item, _ value: Int) {
        guard item.choices.contains(value) else { return }
        var next = ages
        next[item] = value
        apply(next.normalized())
    }

    func resetToDefaults() { apply(CleanupAges()) }

    private func apply(_ next: CleanupAges) {
        guard next != ages else { return }
        ages = next
        guard let defaults else { return }
        for item in CleanupAges.Item.allCases { defaults.set(next[item], forKey: item.key) }
    }
}
