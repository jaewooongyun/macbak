import SwiftUI

/// Connects the screens to the one executor and tells them whether a clean-up is running.
@MainActor
@Observable
final class CleanupRunner {
    private(set) var isRunning = false
    /// Set by `stop()` during a run; the executor asks it before each row, so the row being deleted finishes and none
    /// after it starts.
    private(set) var isStopping = false
    /// The run going is the loop's own (`runShallow`), not one a screen started while the loop waits for it; the menu
    /// footer's stop belongs to the loop's run only.
    private(set) var isLoopRun = false
    /// The run is waiting for a scan in progress and has deleted nothing yet; the run panel says so.
    private(set) var isSettling = false
    @ObservationIgnored private let executor: CleanupExecutor
    /// The row as the screens hold it now, by id; the executor asks it just before deleting each row.
    @ObservationIgnored private let latest: @MainActor (String) -> CleanupCandidate?

    /// Waits for a scan in progress before a run starts.
    @ObservationIgnored private let settle: @MainActor () async -> Void
    /// Drops deleted rows from the lists every screen reads, once a run ends — whoever started it. Done in one place:
    /// the dashboard once only hid them in its own view, and the menu then offered them again.
    @ObservationIgnored private let forget: @MainActor (Set<String>) -> Void
    @ObservationIgnored private let background: BackgroundDeletion
    /// The wait for the latest run's background deletes; the next run cancels it, since its deletes would mix in.
    @ObservationIgnored private var waiting: Task<Void, Never>?

    init(executor: CleanupExecutor = CleanupExecutor(), latest: @escaping @MainActor (String) -> CleanupCandidate? = { _ in nil },
         settle: @escaping @MainActor () async -> Void = {}, forget: @escaping @MainActor (Set<String>) -> Void = { _ in },
         background: BackgroundDeletion = BackgroundDeletion()) {
        self.executor = executor
        self.latest = latest
        self.settle = settle
        self.forget = forget
        self.background = background
    }

    /// - Parameter shallow: the rows were not chosen one by one (the immediate clean-up, the loop), so each must still be
    ///   shallow, unchanged, just before it is deleted.
    func run(_ items: [CleanupCandidate], shallow: Bool = false, byLoop: Bool = false,
             progress: @escaping @MainActor @Sendable (CleanupExecutor.ItemResult) -> Void) async -> CleanupExecutor.Report {
        // Only the call that starts a run owns the flag; a second one must not clear it while the first still deletes.
        guard !isRunning else { return CleanupExecutor.Report(refusal: "이미 정리하는 중입니다.") }
        isRunning = true
        isLoopRun = byLoop
        waiting?.cancel()
        defer {
            isRunning = false
            isStopping = false
            isLoopRun = false
            isSettling = false
        }
        // Set before waiting: a scan asked for from now on waits until this run ends.
        isSettling = true
        await settle()
        isSettling = false
        let latest = latest
        let report = await executor.run(items, latest: { id in await latest(id) }, shallow: shallow,
                                        stop: { [weak self] in await self?.isStopping ?? true }) { result in await progress(result) }
        forget(Set(report.deleted.map(\.id)))
        return report
    }

    /// Waits until the simulators and runtimes `report` deleted are gone from the disk, telling `update` the gain in the
    /// panel's words as it grows; free space measured before that is only a part. Returns at once when there are none.
    func waitForBackground(_ report: CleanupExecutor.Report, update: @escaping @MainActor @Sendable (String) -> Void) async {
        guard !report.pending.isEmpty else { return }
        let background = background, before = report.freeBefore
        update(BackgroundDeletion.text(.waiting, freeBefore: before, free: report.freeAfter))
        let task = Task {
            // Off the main actor: `wait` is nonisolated and only comes back here to update the panel.
            let result = await background.wait(for: report.pending, free: report.freeAfter) { free in
                await update(BackgroundDeletion.text(.waiting, freeBefore: before, free: free))
            }
            // Only the next run cancels it, and that run's panel is no longer this one's to write.
            if let result, result.state != .cancelled { update(BackgroundDeletion.text(result.state, freeBefore: before, free: result.free)) }
        }
        waiting = task
        await task.value
    }

    /// Stops the run going, whoever started it (a screen, the menu, the loop), after the row being deleted.
    func stop() {
        if isRunning { isStopping = true }
    }

    /// The shallow clean-up the loop runs: only rows a source vouches for, through the same checks as any run. Returns
    /// what was deleted, or nil when it failed: the run was refused (another run going, no audit record), or there were
    /// rows and not one could be deleted (open-file list unreadable, stopped before the first). Neither is "nothing".
    func runShallow(_ rows: [CleanupCandidate]) async -> [CleanupExecutor.ItemResult]? {
        let shallow = rows.filter(\.isShallow)
        guard !shallow.isEmpty else { return [] }
        let report = await run(shallow, shallow: true, byLoop: true) { _ in }
        guard report.refusal == nil, !report.deleted.isEmpty else { return nil }
        return report.deleted
    }
}

/// Candidates grouped by status, with selection, a floating selection bar, a confirmation listing exactly what goes, and
/// the real run ticking off each item as it is deleted or skipped.
/// - Note: When rows come or go, or their verdicts change, the ticks the person left stay and only new or newly ready
///   rows start ticked; see `kept` and `reselect`.
struct CleanupBoard<Header: View>: View {
    let candidates: [CleanupCandidate]
    let title: String
    let note: String
    /// A scan is running: while no row has arrived yet, the list's place shows that instead of standing empty.
    var scanning = false
    /// Called after a run, so the owner can scan again and show what is left.
    var onFinished: () -> Void = {}
    let header: (_ selectedBytes: Int64) -> Header

    private struct Pending: Identifiable {
        let id = UUID()
        let items: [CleanupCandidate]
    }

    @Environment(CleanupRunner.self) private var runner
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selected: Set<String>
    @State private var cleaned: Set<String> = []
    @State private var pending: Pending?
    @State private var run: RunProgress?
    @State private var lastReport: CleanupExecutor.Report?
    /// The gain while simulators and runtimes are still being deleted in the background, and once they are gone.
    @State private var settleText: String?
    /// Long protected groups start folded: hundreds of rows nobody can tick would bury the ones that matter.
    @State private var unfolded: Set<CleanupStatus> = []

    /// A group longer than this starts folded when nothing in it can be ticked.
    private static var foldAbove: Int { 6 }

    init(candidates: [CleanupCandidate], title: String, note: String, scanning: Bool = false, onFinished: @escaping () -> Void = {},
         @ViewBuilder header: @escaping (_ selectedBytes: Int64) -> Header) {
        self.candidates = candidates
        self.title = title
        self.note = note
        self.scanning = scanning
        self.onFinished = onFinished
        self.header = header
        _selected = State(initialValue: Self.preselected(candidates))
    }

    static func preselected(_ candidates: [CleanupCandidate]) -> Set<String> {
        Set(candidates.filter(\.isPreselected).map(\.id))
    }

    private var remaining: [CleanupCandidate] { candidates.filter { !cleaned.contains($0.id) } }
    private var selectedItems: [CleanupCandidate] { remaining.filter { selected.contains($0.id) && $0.isSelectable } }
    private var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header(selectedBytes).riseIn(0)
                intro.riseIn(1)
                if let lastReport, run == nil {
                    resultBanner(lastReport).transition(.move(edge: .top).combined(with: .opacity))
                }
                if remaining.isEmpty && scanning {
                    ProgressView("검사하는 중…")
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: 120)
                }
                ForEach(Array(CleanupStatus.allCases.enumerated()), id: \.element) { index, status in
                    let items = remaining.filter { $0.verdict.status == status }
                    if !items.isEmpty { section(status, items).riseIn(2 + index) }
                }
            }
            .readableColumn()
        }
        .softScrollEdges()
        // Floats over the list: rows scroll underneath, which is what the glass is for.
        .floatingBottomBar {
            selectionBar
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 18)
        }
        .sheet(item: $pending) { pending in
            ConfirmCleanupSheet(items: pending.items) { perform(CleanupCandidate.stillCurrent(pending.items, in: candidates)) }
        }
        // Rows came or went, as when the expanded scan adds its rows minutes after the usual ones.
        .onChange(of: candidates.map(\.id)) { before, _ in
            guard run == nil else { return }
            cleaned = []
            selected = Self.kept(selected, idsBefore: before, rows: candidates)
        }
        // The same rows with new verdicts, as when the on-device model has looked: the ids stay, the ticks follow.
        .onChange(of: Self.preselected(candidates)) { before, _ in
            selected = Self.reselect(selected, preselectedBefore: before, rows: candidates)
        }
    }

    /// The ticks after verdicts changed on the same rows: a row that has just become ready is ticked, a row that can no
    /// longer be chosen or that now waits for a hand pick is unticked, and a tick the person removed stays removed.
    static func reselect(_ selected: Set<String>, preselectedBefore: Set<String>, rows: [CleanupCandidate]) -> Set<String> {
        let selectable = Set(rows.filter(\.isSelectable).map(\.id))
        let now = preselected(rows)
        return selected.subtracting(preselectedBefore.subtracting(now)).union(now.subtracting(preselectedBefore)).intersection(selectable)
    }

    /// The run panel's words: while the run waits for a scan in progress it says it will delete once that ends.
    static func wording(settling: Bool) -> RunWording {
        settling ? RunWording(running: "진행 중인 검사가 끝나면 지웁니다", finished: RunWording.cleanup.finished, note: RunWording.cleanup.note,
                              symbol: RunWording.cleanup.symbol) : .cleanup
    }

    /// The ticks after rows came or went: ticks on rows still listed stay as the person left them, a new row ticked to
    /// begin with is ticked, and a row that can no longer be chosen is unticked.
    static func kept(_ selected: Set<String>, idsBefore: [String], rows: [CleanupCandidate]) -> Set<String> {
        let selectable = Set(rows.filter(\.isSelectable).map(\.id))
        return selected.union(preselected(rows).subtracting(idsBefore)).intersection(selectable)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title2.weight(.semibold))
            Text(note).font(.body).foregroundStyle(.secondary)
        }
    }

    private func resultBanner(_ report: CleanupExecutor.Report) -> some View {
        let deleted = report.deleted
        let skipped = report.items.count - deleted.count
        return HStack(spacing: 14) {
            Image(systemName: report.refusal == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.title)
                .foregroundStyle(report.refusal == nil ? .green : .orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(report.refusal ?? "\(deleted.count)개 지움" + (skipped > 0 ? " · \(skipped)개 건너뜀" : ""))
                    .font(.headline)
                if report.refusal == nil {
                    Text(settleText ?? report.gainText).font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("닫기") { withAnimation(reduceMotion ? nil : .smooth) { lastReport = nil } }
                .glassAction()
        }
        .padding(16)
        .background(CardBackground())
    }

    private func section(_ status: CleanupStatus, _ items: [CleanupCandidate]) -> some View {
        let foldable = items.count > Self.foldAbove && !items.contains(where: \.isSelectable)
        let folded = foldable && !unfolded.contains(status)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                StatusTag(status).font(.headline)
                Text("\(items.count)개 · \(items.reduce(0) { $0 + $1.bytes }.diskText)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if foldable {
                    Button {
                        withAnimation(reduceMotion ? nil : .smooth) {
                            if folded { unfolded.insert(status) } else { unfolded.remove(status) }
                        }
                    } label: {
                        Label(folded ? "모두 보기" : "접기", systemImage: folded ? "chevron.down" : "chevron.up")
                            .labelStyle(.titleAndIcon)
                            .font(.callout)
                    }
                    .buttonStyle(.borderless)
                }
            }
            Text(status.groupNote).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if folded {
                foldedSummary(items)
            } else {
                // Lazy: a real scan lists a few hundred rows, and laying them all out on every scroll or hover pinned the main thread.
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        CandidateRow(item: item, isOn: binding(for: item.id), selectable: item.isSelectable && run == nil)
                            .transition(.asymmetric(insertion: .opacity, removal: .move(edge: .trailing).combined(with: .opacity)))
                        if item.id != items.last?.id { Divider().padding(.leading, 82) }
                    }
                }
                .padding(4)
                .background(CardBackground())
            }
        }
    }

    /// A folded group: its three largest rows by name and size, so what is kept is visible without the full list.
    private func foldedSummary(_ items: [CleanupCandidate]) -> some View {
        let largest = items.sorted { $0.bytes > $1.bytes }.prefix(3)
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(largest)) { item in
                // The list rows' columns: the checkbox's room, then the 28pt icon, so the icons line up with the rows above.
                HStack(spacing: 14) {
                    Color.clear.frame(width: 14, height: 1)
                    Image(systemName: item.symbol).font(.title3).foregroundStyle(.secondary).frame(width: 28)
                    Text(item.name).font(.callout.weight(.medium)).lineLimit(1)
                    Text(item.verdict.reason).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 8)
                    Text((item.lowerBound ? "≥ " : "") + item.bytes.diskText).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if items.count > largest.count {
                Text("그 밖에 \(items.count - largest.count)개").font(.callout).foregroundStyle(.tertiary)
                    .padding(.leading, 14 + 14 + 28 + 14)
            }
        }
        // The list's card inset (4) plus the row's own (14).
        .padding(.vertical, 14)
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardBackground())
    }

    /// The selection total in a glass capsule beside the action; confirming morphs the capsule into the run panel.
    private var selectionBar: some View {
        let reviewCount = selectedItems.filter { $0.verdict.status == .review }.count
        return RunBar(
            actionTitle: "정리…",
            canRun: !selectedItems.isEmpty && !runner.isRunning,
            run: run,
            wording: Self.wording(settling: runner.isSettling),
            total: { Int64($0).diskText },
            start: { pending = Pending(items: selectedItems) },
            close: {
                withAnimation(reduceMotion ? nil : Theme.morph) { run = nil }
                onFinished()
            },
            stop: { runner.stop() },
            stopping: runner.isStopping
        ) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(selectedBytes.diskText)
                        .font(Theme.numeral(20))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(selectedBytes)))
                    Text("\(selectedItems.count)개 선택 · 폴더 크기 합계").font(.callout).foregroundStyle(.secondary)
                }
                if reviewCount > 0 {
                    Divider().frame(height: 28)
                    StatusTag(title: "\(CleanupStatus.review.title) \(reviewCount)개 포함", symbol: CleanupStatus.review.symbol, tint: CleanupStatus.review.tint)
                        .font(.callout)
                        .help("확인이 필요한 항목입니다. 내용을 확인한 뒤 고르세요.")
                        .transition(.opacity)
                }
            }
        }
        .animation(reduceMotion ? nil : .smooth, value: reviewCount > 0)
        .animation(reduceMotion ? nil : .smooth, value: selectedBytes)
    }

    /// Deletes for real. Each finished item ticks off and leaves the list; skipped ones stay with their reason.
    private func perform(_ items: [CleanupCandidate]) {
        withAnimation(reduceMotion ? nil : Theme.morph) {
            lastReport = nil
            settleText = nil
            run = RunProgress(steps: items.map(\.runStep))
        }
        Task {
            let report = await runner.run(items) { result in
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
                    if let reason = result.outcome.reason, !result.outcome.succeeded { run?.problems[result.id] = reason }
                    if result.outcome.succeeded {
                        cleaned.insert(result.id)
                        selected.remove(result.id)
                    }
                    run?.done += 1
                }
            }
            withAnimation(reduceMotion ? nil : .smooth) {
                if let refusal = report.refusal {
                    run?.problems = Dictionary(uniqueKeysWithValues: items.map { ($0.id, refusal) })
                    run?.done = items.count
                }
                run?.outcome = report.refusal ?? report.gainText
                lastReport = report
            }
            await runner.waitForBackground(report) { text in
                withAnimation(reduceMotion ? nil : .smooth) {
                    settleText = text
                    run?.outcome = text
                }
            }
        }
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { selected.contains(id) },
            set: { isOn in
                withAnimation(reduceMotion ? nil : .smooth) {
                    if isOn { selected.insert(id) } else { selected.remove(id) }
                }
            }
        )
    }
}

/// The last look before deleting: every item with where it is and how big, a warning when choices are included, and
/// a destructive button that is not the default, so Return cannot delete by accident.
struct ConfirmCleanupSheet: View {
    let items: [CleanupCandidate]
    let confirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let total = items.reduce(Int64(0)) { $0 + $1.bytes }
        let review = items.filter { $0.verdict.status == .review }.count
        VStack(alignment: .leading, spacing: 16) {
            Label("\(items.count)개를 지웁니다", systemImage: "trash")
                .font(.title2.weight(.semibold))
            Text("휴지통을 거치지 않고 바로 지웁니다. 되돌릴 수 없습니다. 지우기 직전에 하나씩 다시 확인해서, 그사이 쓰기 시작한 것은 건너뜁니다.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if review > 0 {
                StatusTag(title: "\(CleanupStatus.review.title) \(review)개 포함 — 내용을 확인했는지 다시 봐 주세요", symbol: CleanupStatus.review.symbol, tint: CleanupStatus.review.tint)
                    .font(.callout)
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(items) { item in
                        HStack(spacing: 10) {
                            Image(systemName: item.symbol).foregroundStyle(.secondary).frame(width: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.name).font(.body.weight(.medium)).lineLimit(1)
                                Text(location(of: item)).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer(minLength: 8)
                            Text(item.bytes.diskText).font(.body.monospacedDigit())
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 280)
            HStack {
                Text("합계 \(total.diskText) · 실제로 늘어나는 공간은 더 작을 수 있음").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("취소", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("\(items.count)개 지우기", role: .destructive) {
                    dismiss()
                    confirm()
                }
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private func location(of item: CleanupCandidate) -> String {
        guard let first = item.targets.first else { return item.detail }
        let path = ScanSupport.display(first.path.path(percentEncoded: false), home: FileManager.default.homeDirectoryForCurrentUser)
        return item.targets.count > 1 ? "\(path) 외 \(item.targets.count - 1)곳" : path
    }
}

struct CandidateRow: View {
    let item: CleanupCandidate
    @Binding var isOn: Bool
    let selectable: Bool

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 14) {
            // The label stays for VoiceOver; labelsHidden only removes it visually.
            Toggle(item.name, isOn: $isOn)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .opacity(selectable ? 1 : 0)
                .disabled(!selectable)
                .accessibilityHidden(!selectable)
            Image(systemName: item.symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(item.name).font(.body.weight(.medium))
                    if item.aiEvidence != nil { AIBadge() }
                }
                Text(item.detail).font(.callout).foregroundStyle(.secondary)
                // Every ready row shares one reason, which the section header already states.
                if item.verdict.status != .ready {
                    Text(item.verdict.reason).font(.callout).foregroundStyle(.secondary)
                }
                if let seen = item.aiEvidence {
                    // The model's own words, in English: that is the language its rules were measured in.
                    Text("기기 AI의 근거(원문): \(seen)").font(.callout).foregroundStyle(.tertiary).lineLimit(2)
                }
                if let command = item.toolCommand { CommandChip(command: command) }
            }
            Spacer(minLength: 16)
            Text((item.lowerBound ? "≥ " : "") + item.bytes.diskText).font(.body.monospacedDigit())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Theme.rowShape.fill(.quaternary.opacity(hovering && selectable ? 0.8 : 0)))
        .contentShape(Rectangle())
        .help(item.verdict.reason)
        .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hovering = inside } }
        .onTapGesture { if selectable { isOn.toggle() } }
    }
}
