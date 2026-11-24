import Foundation
import Observation

/// Looks, when a person asks, at folders nothing could tell outside the cache areas, with the explorer's two sessions
/// in the model's low lane. Where both call a folder re-created by its app it proposes a rule; only the person's
/// approval makes the folder a choice (`CleanupCoordinator.approve`).
/// - Important: A scan, the loop and the menu bar never ask it: only a click, for one row or at most `batchLimit`. An
///   answer never ticks a row or changes one by itself.
@MainActor
@Observable
final class RuleAdvisor {
    enum Answer: Equatable, Sendable {
        /// Waiting for its turn, or being looked at.
        case asking
        /// Both sessions call it re-created by its app: the person may approve a rule. The evidence is the model's own
        /// words, in English.
        case proposal(evidence: String)
        /// The model saw the person's data, settings or an image in it.
        case kept(evidence: String)
        /// The model could not tell, failed or ran out of time; the reason says which.
        case unsure(reason: String)
        /// The model gave no answer this time: it cannot run here now (Apple Intelligence off, its model still
        /// downloading), it failed, or it ran out of time. Asking again tries anew.
        case unavailable(reason: String)
    }

    struct Progress: Equatable, Sendable {
        var done: Int
        var total: Int
    }

    /// Answers by row id, each with what the model saw. A rescan keeps an answer while the folder shows the same names;
    /// once they change, the answer no longer counts.
    private(set) var answers: [String: (input: ExploreInput, answer: Answer)] = [:]
    /// How far the asking has come, or nil when none is going.
    private(set) var progress: Progress?
    @ObservationIgnored private var queue: [(id: String, input: ExploreInput)] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let slot: ModelSlot
    @ObservationIgnored private let look: @Sendable (ExploreInput) async -> CacheExplorer.Finding
    @ObservationIgnored private let unavailable: @Sendable () -> String?

    init(slot: ModelSlot = .shared, look: @escaping @Sendable (ExploreInput) async -> CacheExplorer.Finding = CacheExplorer.look(at:),
         unavailable: @escaping @Sendable () -> String? = CacheExplorer.unavailableReason) {
        self.slot = slot
        self.look = look
        self.unavailable = unavailable
    }

    /// At most this many rows a click: about two minutes of the model at 5.5 s a row (2026-11-03).
    static let batchLimit = 20

    /// The answer for a row whose folder shows `input` now; nil when it was not asked about with these names.
    func answer(for id: String, input: ExploreInput) -> Answer? {
        answers[id].flatMap { $0.input == input ? $0.answer : nil }
    }

    /// Whether `ask` takes the row: never asked with the names it shows now, or the model could not run last time.
    func mayAsk(_ id: String, input: ExploreInput) -> Bool {
        switch answer(for: id, input: input) {
        case nil, .unavailable?: true
        default: false
        }
    }

    /// Asks about the rows not asked yet with the names they show now, at most `batchLimit`, after those already waiting.
    func ask(_ items: [(id: String, input: ExploreInput)]) {
        let new = items.filter { mayAsk($0.id, input: $0.input) }.prefix(Self.batchLimit)
        guard !new.isEmpty else { return }
        if let reason = unavailable() {
            for item in new { answers[item.id] = (item.input, .unavailable(reason: reason)) }
            return
        }
        for item in new { answers[item.id] = (item.input, .asking) }
        queue += new
        progress = Progress(done: progress?.done ?? 0, total: (progress?.total ?? 0) + new.count)
        guard task == nil else { return }
        task = Task { [weak self] in await self?.work() }
    }

    private func work() async {
        while !queue.isEmpty {
            let item = queue.removeFirst()
            let look = look
            let finding = await slot.run(.low, deadline: CacheExplorer.itemDeadline) { await look(item.input) }
            // The folder was asked about again with other names meanwhile: that newer asking stands.
            if answers[item.id]?.input == item.input {
                answers[item.id] = (item.input, finding.map { Self.answer($0, input: item.input) }
                    ?? .unavailable(reason: "기기 AI가 제시간에 답하지 못했습니다."))
            }
            progress?.done += 1
        }
        progress = nil
        task = nil
    }

    /// A proposal only where both sessions agree it is re-created (`Finding.offered`) and the folder's names show no
    /// one's state; a seen warning or user data keeps it; anything else is unsure.
    /// - Parameter input: the folder and its names as the rules list them; every name directly inside is read again.
    nonisolated static func answer(_ finding: CacheExplorer.Finding, input: ExploreInput) -> Answer {
        if finding.decision == "error" { return .unavailable(reason: "기기 AI가 답하지 못했습니다.") }
        if finding.offered {
            guard let name = CacheRules.stateName(of: input.url, listing: input.inside) else { return .proposal(evidence: finding.evidence) }
            return .unsure(reason: "기기 AI는 다시 만들어진다고 봤지만, 안에 \(name)처럼 기록·설정을 뜻하는 이름이 있어 규칙을 제안하지 않습니다.")
        }
        if finding.vetoes { return .kept(evidence: finding.evidence) }
        return .unsure(reason: "기기 AI도 판단하지 못했습니다.")
    }
}
