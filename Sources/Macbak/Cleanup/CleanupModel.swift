import Foundation

/// One thing a clean-up deletes, as it was when scanned. The executor checks it again, item by item, right before deleting.
struct CleanupTarget: Hashable, Sendable {
    enum Action: Hashable, Sendable {
        /// The item and everything inside it. Links inside are removed as links; what they point to is untouched.
        case removeItem
        /// Exactly these files, fixed at scan time. A file that changed, moved or opened since is skipped, and files that
        /// appeared later are never touched.
        case removeFiles([FileStamp])
        /// `xcrun simctl delete`, only while the device is still shut down. `path` is its data folder, for the open-files check.
        case deleteSimulator(udid: String)
        /// `xcrun simctl runtime delete`, only while every simulator of that OS is shut down. `path` is its disk image.
        case deleteRuntime(identifier: String)
    }

    /// The item to delete, or the folder holding the listed files.
    let path: URL
    /// The allowed root `path` must sit strictly inside.
    let root: URL
    let identity: FileIdentity?
    let action: Action
    /// Set for a folder outside every allowed root: deleted only as exactly this folder, after the grant is judged again.
    var grant: TargetGrant?
}

/// What else, besides its own files, must be idle when a row is deleted. The executor checks these again right before.
struct CleanupGuards: Hashable, Sendable {
    /// Folders where an open file protects the row too, such as a workspace's own folder.
    var watchPaths: [URL] = []
    /// Apps whose running protects it.
    var bundleIDs: [String] = []
    /// AI tools whose running protects it.
    var toolIDs: [String] = []
}

/// A file as it was when listed for deletion.
struct FileStamp: Hashable, Sendable {
    let path: String
    let identity: FileIdentity
    let modified: Date
    let bytes: Int64
}

extension CleanupCandidate {
    /// How long a scan result may be acted on. Past it, the rows are scanned again before anything is deleted.
    /// - Note: This bounds how old the "untouched for three days" judgement can be; it does not re-check it. A cache
    ///   used a few minutes after the scan is caught only through its open files.
    ///   ponytail: a ten-minute ceiling; re-walk each target's newest date at deletion if that window ever matters.
    static let resultLifetime: TimeInterval = 600

    /// Whether a person may tick it: only ready or needs-a-choice rows that have something to delete. Rows shown for
    /// information only (old conversation logs, finished job files) have no targets.
    var isSelectable: Bool {
        !targets.isEmpty && (verdict.status == .ready || verdict.status == .review)
    }

    /// Ticked to begin with: only rows that passed every check, need no choice, and may go without being picked.
    var isPreselected: Bool { !manualOnly && !targets.isEmpty && verdict.status == .ready }

    /// In the menu bar's immediate clean-up: ticked, and vouched for by a curated source.
    var isShallow: Bool { trusted && isPreselected }

    /// The confirmed rows that the latest scan still offers unchanged: a rescan while the confirmation was open may have
    /// protected or replaced some, and those are dropped rather than deleted on the old verdict.
    static func stillCurrent(_ confirmed: [CleanupCandidate], in latest: [CleanupCandidate]) -> [CleanupCandidate] {
        let byID = Dictionary(latest.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return confirmed.compactMap { old in
            guard let now = byID[old.id], now.isSelectable, now.targets == old.targets else { return nil }
            return now
        }
    }
}
