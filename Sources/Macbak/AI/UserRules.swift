import Foundation

/// The folders a person made clean-up choices after the on-device model saw them as re-created by their app. A rule is
/// one exact folder, relative to the home folder; it only turns a row nothing could tell (`model`) into a choice that is
/// never ticked to begin with (`CacheRules.tier(…, userRules:)`).
/// - Important: Every change reads, changes and writes the file under an exclusive lock on a separate lock file, so the
///   app and `--scan-report` taking turns never lose a rule. A file that does not read as this version's rules (damaged,
///   or written by a newer Macbak) gives no rules, and changes are refused rather than written over it.
struct UserRuleStore: Sendable {
    enum State: Equatable, Sendable {
        /// No file yet.
        case none
        /// A file that does not read as this version's rules.
        case unreadable
        case rules(Set<String>)

        var paths: Set<String> { if case .rules(let paths) = self { paths } else { [] } }
    }

    private struct Stored: Codable {
        var schemaVersion: Int
        var folders: [String]
    }

    static let schemaVersion = 1
    let url: URL

    init(home: URL) {
        url = home.appending(path: "Library/Application Support/Macbak/user-rules.json")
    }

    func load() -> State {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return .none }
        guard let data = try? Data(contentsOf: url), let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.schemaVersion == Self.schemaVersion else { return .unreadable }
        return .rules(Set(stored.folders))
    }

    /// Adds the folder. False when the file is unreadable (it stays as it is) or the lock or the write failed.
    func approve(_ relative: String) -> Bool { change { _ = $0.insert(relative) } }

    /// Takes the folder away. False likewise.
    func revoke(_ relative: String) -> Bool { change { _ = $0.remove(relative) } }

    private func change(_ edit: (inout Set<String>) -> Void) -> Bool {
        let folder = url.deletingLastPathComponent()
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return false }
        let lock = open(folder.appending(path: "user-rules.lock").path(percentEncoded: false), O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { return false }
        defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { return false }
        defer { flock(lock, LOCK_UN) }
        let state = load()
        if state == .unreadable { return false }
        var folders = state.paths
        edit(&folders)
        guard let data = try? JSONEncoder().encode(Stored(schemaVersion: Self.schemaVersion, folders: folders.sorted())) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}
