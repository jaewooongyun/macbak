import Foundation

/// Conversation logs of one tool, counted from file names and modification times only.
struct SessionStats: Equatable, Sendable {
    var logs = 0
    /// Logs below a conversation's folder, such as subagent logs; counted apart so `logs` stays one per conversation.
    var nestedLogs = 0
    var projects = 0
    var within5m = 0
    var within1h = 0
    var within24h = 0
    var within7d = 0
}

/// Background jobs of one tool, by the single state field of each job.
struct JobStats: Equatable, Sendable {
    var running = 0
    var waiting = 0
    var finished = 0
    /// The state file was missing or unreadable. Never folded into zero.
    var unknown = 0
}

/// Per-tool activity, keyed by tool id.
struct AIActivity: Equatable, Sendable {
    var sessions: [String: SessionStats] = [:]
    var jobs: [String: JobStats] = [:]
}

extension SessionLog {
    /// Visits every log file: its URL, whether it sits below a conversation folder, its project (if the layout has one) and the requested values.
    /// - Note: Only `perProject` has nested logs; under `anywhere` every depth is an ordinary log (Codex keeps date folders).
    func forEachLog(home: URL, keys: Set<URLResourceKey>, _ visit: (URL, _ nested: Bool, _ project: String?, URLResourceValues) -> Void) {
        let files = FileManager.default
        let base = home.appending(path: root)
        let allKeys = keys.union([.isRegularFileKey])

        func walk(_ folder: URL, project: String?, nestable: Bool) {
            let depth = folder.standardizedFileURL.pathComponents.count
            guard let walker = files.enumerator(at: folder, includingPropertiesForKeys: Array(allKeys), errorHandler: { _, _ in true }) else { return }
            for case let url as URL in walker where url.pathExtension == fileExtension {
                guard let values = try? url.resourceValues(forKeys: allKeys), values.isRegularFile == true else { continue }
                let nested = nestable && url.standardizedFileURL.pathComponents.count > depth + 1
                visit(url, nested, project, values)
            }
        }

        switch layout {
        case .anywhere:
            walk(base, project: nil, nestable: false)
        case .perProject(let folder):
            let projects = (try? files.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for project in projects where (try? project.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                walk(folder.isEmpty ? project : project.appending(path: folder), project: project.lastPathComponent, nestable: true)
            }
        }
    }

    func stats(home: URL, now: Date) -> SessionStats {
        var stats = SessionStats()
        var projects: Set<String> = []
        forEachLog(home: home, keys: [.contentModificationDateKey]) { _, nested, project, values in
            guard !nested else { stats.nestedLogs += 1; return }
            stats.logs += 1
            if let project { projects.insert(project) }
            guard let modified = values.contentModificationDate else { return }
            let age = now.timeIntervalSince(modified)
            if age < 300 { stats.within5m += 1 }
            if age < 3600 { stats.within1h += 1 }
            if age < 86_400 { stats.within24h += 1 }
            if age < 7 * 86_400 { stats.within7d += 1 }
        }
        stats.projects = projects.count
        return stats
    }
}

extension JobStore {
    func jobFolders(home: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: home.appending(path: root), includingPropertiesForKeys: nil)) ?? []
    }

    /// The single `field` of the job's state file; nil when the file is missing or unreadable.
    func state(of job: URL) -> String? {
        guard let data = try? Data(contentsOf: job.appending(path: stateFile)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object[field] as? String
    }

    func stats(home: URL) -> JobStats {
        jobFolders(home: home).reduce(into: JobStats()) { stats, job in
            let state = state(of: job)
            if let state, running.contains(state) {
                stats.running += 1
            } else if let state, waiting.contains(state) {
                stats.waiting += 1
            } else if let state, finished.contains(state) {
                stats.finished += 1
            } else {
                stats.unknown += 1
            }
        }
    }
}

enum AIActivityReader {
    static func read(catalog: [AITool] = AITool.catalog, home: URL = FileManager.default.homeDirectoryForCurrentUser, now: Date = .now) -> AIActivity {
        var activity = AIActivity()
        for tool in catalog {
            if let log = tool.sessions { activity.sessions[tool.id] = log.stats(home: home, now: now) }
            if let jobs = tool.jobs { activity.jobs[tool.id] = jobs.stats(home: home) }
        }
        return activity
    }
}
