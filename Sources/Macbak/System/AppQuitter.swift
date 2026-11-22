import AppKit

extension AppMemory {
    /// This app, Finder and company security or device-management software are never offered for quitting.
    var isQuittable: Bool {
        id != ProcessInfo.processInfo.processIdentifier && bundleID != "com.apple.finder"
            && !CleanupRoots.isManagedSoftware(bundleID ?? "") && !CleanupRoots.isManagedSoftware(name)
    }
}

/// A running app that looks unused, and why. Memory is shown beside it but never decides the order.
struct IdleApp: Identifiable {
    let app: AppMemory
    /// Time since it was last in front.
    let idle: TimeInterval
    /// It has not come to the front since tracking began, so `idle` is a lower bound.
    let atLeast: Bool
    /// When it last came to the front, if that was seen.
    var lastUsed: Date?

    var id: pid_t { app.id }
    var windowless: Bool { app.windows == 0 }

    var reason: String {
        var parts: [String] = []
        if windowless { parts.append("창 없이 실행 중") } else if app.isHidden { parts.append("숨김") }
        parts.append((atLeast ? "적어도 " : "") + Self.duration(idle) + " 동안 안 씀")
        return parts.joined(separator: " · ")
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(max(minutes, 1))분" }
        let hours = minutes / 60
        return hours < 48 ? "\(hours)시간" : "\(hours / 24)일"
    }
}

/// Apps a person may choose to quit from the window. Nothing is pre-ticked and the menu bar never offers them: an app
/// someone runs is theirs to judge.
enum IdleApps {
    /// An app brought to the front within this long, or in front now, counts as in use.
    static let inUseWithin: TimeInterval = 30 * 60

    /// Apps without a window that are not in use, then apps idle for `inUseWithin` or longer; windowless first, then the
    /// longest idle. Without a recorded activation an app counts as idle since tracking began (or since it launched, if later).
    static func candidates(_ apps: [AppMemory], lastActive: [pid_t: Date], trackingSince: Date, now: Date) -> [IdleApp] {
        apps.compactMap { app -> IdleApp? in
            guard app.isQuittable, !app.isActive else { return nil }
            // A record that cannot be tied to this launch may be an earlier process's, or this app's own recent use:
            // unknown either way, so it is not offered.
            if lastActive[app.id] != nil, app.launched == nil { return nil }
            // A pid outlives its app: an activation from before this launch belonged to an earlier process.
            let activated = lastActive[app.id].flatMap { date in (app.launched.map { date >= $0 } ?? true) ? date : nil }
            let since: Date
            let atLeast: Bool
            if let active = activated {
                since = active
                atLeast = false
            } else if let launched = app.launched, launched > trackingSince {
                since = launched
                atLeast = false
            } else {
                since = trackingSince
                atLeast = true
            }
            let idle = now.timeIntervalSince(since)
            if let active = activated, now.timeIntervalSince(active) < inUseWithin { return nil }
            guard app.windows == 0 || idle >= inUseWithin else { return nil }
            return IdleApp(app: app, idle: idle, atLeast: atLeast, lastUsed: activated)
        }
        .sorted { ($0.windowless ? 0 : 1, -$0.idle) < ($1.windowless ? 0 : 1, -$1.idle) }
    }
}

/// Apps a person ticked, kept as they were when ticked. A row whose pid now belongs to another app shows unticked, and
/// quitting goes by the ticked app's identity, so a reused pid can never carry the tick over to an app nobody picked.
struct AppPicks {
    private var byPID: [pid_t: (app: AppMemory, at: Date)] = [:]

    var isEmpty: Bool { byPID.isEmpty }

    func contains(_ app: AppMemory) -> Bool {
        guard let picked = byPID[app.id]?.app else { return false }
        return picked.bundleID == app.bundleID && picked.launched == app.launched
    }

    /// Ticked, and not brought to the front since: using an app again takes its tick away for good, so it does not come
    /// back ticked when the app goes idle again.
    func isTicked(_ row: IdleApp) -> Bool {
        guard contains(row.app), let at = byPID[row.id]?.at else { return false }
        return row.lastUsed.map { $0 <= at } ?? true
    }

    mutating func set(_ app: AppMemory, _ on: Bool, at date: Date = .now) {
        byPID[app.id] = on ? (app, date) : nil
    }

    /// The ticked apps that are still unused now.
    func chosen(from idle: [IdleApp]) -> [AppMemory] {
        idle.filter(isTicked).map(\.app)
    }
}

/// What quitting needs from a running app; `NSRunningApplication` in the app, a fake in tests.
@MainActor
protocol QuittableApp: AnyObject {
    var bundleIdentifier: String? { get }
    var launchDate: Date? { get }
    var isTerminated: Bool { get }
    func terminate() -> Bool
}

extension NSRunningApplication: QuittableApp {}

/// Asks the apps a person picked to quit, the way the Dock's Quit does: each app may ask to save its documents, or
/// decline. It never force-quits.
@MainActor
enum AppQuitter {
    enum Outcome: Equatable, Sendable {
        case quit
        /// Asked, but still running after the wait — usually showing a save dialog.
        case stillOpen
        case declined
        case gone
        /// The pid now belongs to a different process than the one shown.
        case changed
        case notAllowed

        var reason: String? {
            switch self {
            case .quit: nil
            case .stillOpen: "아직 열려 있음 · 저장할지 묻는 중일 수 있음"
            case .declined: "앱이 종료를 거절함"
            case .gone: "이미 종료됨"
            case .changed: "다른 앱으로 바뀜"
            case .notAllowed: "종료하지 않는 앱"
            }
        }
    }

    /// - Parameters:
    ///   - resolve: the running app for a pid now; nil when it is gone.
    ///   - wait: how long to watch each app close before reporting it as still open.
    static func quit(_ app: AppMemory, resolve: (pid_t) -> QuittableApp? = { NSRunningApplication(processIdentifier: $0) },
                     wait: Duration = .seconds(10)) async -> Outcome {
        guard app.isQuittable else { return .notAllowed }
        guard let running = resolve(app.id), !running.isTerminated else { return .gone }
        guard running.bundleIdentifier == app.bundleID, running.launchDate == app.launched else { return .changed }
        guard running.terminate() else { return .declined }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: wait)
        while clock.now < deadline {
            if running.isTerminated { return .quit }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return running.isTerminated ? .quit : .stillOpen
    }
}
