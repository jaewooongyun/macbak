import Foundation

/// Empties the Trash by asking Finder, as Finder's own "Empty Trash" does: Finder deletes, and this app never reads what
/// is in the Trash, which macOS keeps private.
/// - Important: The first request makes macOS ask whether Macbak may control Finder; until that is allowed nothing is
///   emptied. As with every clean-up, nothing is asked of Finder unless the start record is written first.
/// - Note: The Trash's size cannot be read beforehand, so the free space is measured before and after instead.
struct TrashEmptier: Sendable {
    struct Result: Sendable, Equatable {
        let emptied: Bool
        let message: String
    }

    /// Finder's reply, "ok" or "error <number>", on stdout; nil when `osascript` could not run or timed out.
    var askFinder: @Sendable () -> Command.Output?
    var freeSpace: @Sendable () -> Int64?
    var audit: CleanupAudit
    /// Finder may still be handing space back when it replies.
    var settle: Duration = .seconds(2)

    static func live() -> TrashEmptier {
        let script = ["try", "with timeout of 600 seconds", "tell application \"Finder\" to empty trash", "end timeout", "return \"ok\"",
                      "on error errorText number errorNumber", "return \"error \" & errorNumber", "end try"]
        return TrashEmptier(
            askFinder: { Command.run("/usr/bin/osascript", script.flatMap { ["-e", $0] }, timeout: .seconds(620)) },
            // A fresh URL per reading (`SystemReader.disk`): a reused URL keeps its first values.
            freeSpace: { SystemReader.disk()?.available },
            audit: .live())
    }

    /// Blocks until Finder answers, up to ten minutes; call it off the main actor.
    func run() -> Result {
        let time = ISO8601DateFormatter()
        do {
            try audit.append(["event": "trash-start", "time": time.string(from: .now)])
        } catch {
            return Result(emptied: false, message: "정리 기록을 남길 수 없어 비우지 않았습니다")
        }
        let before = freeSpace()
        let reply = askFinder()
        Thread.sleep(forTimeInterval: settle.seconds)
        let report = CleanupExecutor.Report(freeBefore: before, freeAfter: freeSpace())
        let result = Self.result(reply, gain: report.gainText)
        try? audit.append(["event": "trash-end", "time": time.string(from: .now), "outcome": result.message,
                           "freeBefore": report.freeBefore.map(String.init) ?? "?", "freeAfter": report.freeAfter.map(String.init) ?? "?"])
        return result
    }

    static func result(_ reply: Command.Output?, gain: String) -> Result {
        guard let reply, reply.status == 0 else { return Result(emptied: false, message: "Finder에 요청하지 못했습니다") }
        switch String(decoding: reply.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) {
        case "ok":
            return Result(emptied: true, message: "휴지통을 비웠습니다 · " + gain)
        case "error -1743":
            return Result(emptied: false, message: "Finder를 제어할 권한이 없습니다 · 시스템 설정 > 개인정보 보호 및 보안 > 자동화에서 Macbak의 Finder를 켜 주세요")
        case let other:
            return Result(emptied: false, message: "Finder가 비우지 못했습니다 (\(other))")
        }
    }
}
