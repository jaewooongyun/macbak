import SwiftUI

/// One thing a run works through: a group of folders being deleted, or an app being closed.
struct RunStep: Identifiable {
    enum Icon {
        case symbol(String)
        case app(NSImage?)
    }

    let id: String
    let name: String
    let icon: Icon
    let amount: Double
    let amountText: String
}

/// A run's progress, moved on by its owner as each step actually finishes.
struct RunProgress {
    let steps: [RunStep]
    var done = 0
    /// Steps that did not complete, with the reason shown in place of the tick.
    var problems: [String: String] = [:]
    /// What actually changed, shown once the run ends — for example the free space measured before and after.
    var outcome: String?

    var finished: Bool { done >= steps.count }
    var progress: Double { steps.isEmpty ? 1 : Double(done) / Double(steps.count) }
    var amountSoFar: Double { steps.prefix(done).filter { problems[$0.id] == nil }.reduce(0) { $0 + $1.amount } }

    /// Moves `done` on with a beat between steps, for runs that change nothing and only show the steps.
    @MainActor
    static func play(_ steps: [RunStep], reduceMotion: Bool, advance: (RunStep) -> Void) async {
        try? await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 350))
        for step in steps {
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { advance(step) }
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 260))
        }
    }
}

struct RunWording {
    let running: String
    let finished: String
    /// Says what the run really does.
    let note: String
    /// The mark in the middle of the progress ring while the run goes: what kind of work it is.
    let symbol: String

    static let cleanup = RunWording(running: "지우는 중…", finished: "정리 끝", note: "휴지통을 거치지 않고 지웁니다", symbol: "eraser")
    static let memoryCleanup = RunWording(running: "정리하는 중…", finished: "정리 끝", note: "시뮬레이터는 끄고, 앱에는 정상 종료를 요청합니다",
                                          symbol: "memorychip")
    static let shutdownSimulators = RunWording(running: "시뮬레이터를 끄는 중…", finished: "끄기 끝", note: "기기와 데이터는 그대로, 실행 중이던 앱만 닫힘",
                                               symbol: "power")
    static let emptyTrash = RunWording(running: "휴지통을 비우는 중…", finished: "비우기 끝", note: "Finder가 휴지통의 모든 파일을 지웁니다", symbol: "trash")
}

extension AppMemory {
    var runStep: RunStep { RunStep(id: "\(id)", name: name, icon: .app(icon), amount: Double(total), amountText: totalText) }
}

extension IdleSession {
    var runStep: RunStep {
        RunStep(id: "session.\(id)", name: record.name, icon: .symbol("sparkles"), amount: Double(footprint), amountText: footprint.memoryText)
    }
}

extension OrphanProcess {
    var runStep: RunStep {
        RunStep(id: "orphan.\(pid)", name: name, icon: .symbol("terminal"), amount: Double(footprint ?? 0), amountText: footprint?.memoryText ?? "–")
    }
}

extension CleanupCandidate {
    var runStep: RunStep { RunStep(id: id, name: name, icon: .symbol(symbol), amount: Double(bytes), amountText: bytes.diskText) }
}

/// A floating glass bar: a summary capsule beside an action. While its owner has a run going, the capsule morphs into a
/// `RunPanel` that ticks off the steps, and shrinks back on "완료".
/// - Note: On macOS 26 and later the morph is Liquid Glass's own (`glassEffectID` in one container); before, a cross-fade.
struct RunBar<Summary: View>: View {
    let actionTitle: String
    let canRun: Bool
    let run: RunProgress?
    let wording: RunWording
    let total: (Double) -> String
    let start: () -> Void
    let close: () -> Void
    /// Shown as "중단" while a run goes, when the run can be stopped.
    var stop: (() -> Void)? = nil
    var stopping = false
    @ViewBuilder let summary: () -> Summary

    @Namespace private var glass

    var body: some View {
        GlassGroup(spacing: 10) {
            if let run {
                RunPanel(run: run, wording: wording, total: total, done: close, stop: stop, stopping: stopping)
                    .floatingGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous), id: "bar", namespace: glass)
            } else {
                HStack(spacing: 10) {
                    summary()
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .floatingGlass(in: Capsule(), id: "bar", namespace: glass)
                    Button(actionTitle, action: start)
                        .prominentAction()
                        .controlSize(.extraLarge)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canRun)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// The panel a run plays in: a ring that fills, steps that tick off (or show why they did not), and the running total.
struct RunPanel: View {
    let run: RunProgress
    let wording: RunWording
    let total: (Double) -> String
    let done: () -> Void
    /// Asks the run to stop after the step in progress; nil for runs that cannot stop part way.
    var stop: (() -> Void)? = nil
    var stopping = false
    /// nil fills the space offered, as in the menu bar panel.
    var width: CGFloat? = 440
    var visibleSteps = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 18) {
                ProgressRing(progress: run.progress, finished: run.finished, symbol: wording.symbol)
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.finished ? wording.finished : wording.running)
                        .font(.headline)
                        .contentTransition(.opacity)
                    Text(total(run.amountSoFar))
                        .font(Theme.numeral(30))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: run.amountSoFar))
                    Text(run.outcome ?? "\(run.done) / \(run.steps.count) · \(wording.note)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(spacing: 6) {
                ForEach(Array(run.steps.prefix(visibleSteps).enumerated()), id: \.element.id) { index, step in
                    StepRow(step: step, state: state(of: step, at: index))
                }
                if run.steps.count > visibleSteps {
                    let hidden = run.steps.dropFirst(visibleSteps)
                    let problems = hidden.filter { run.problems[$0.id] != nil }.count
                    Text("외 \(hidden.count)개" + (problems > 0 ? " · 건너뜀 \(problems)개" : "")).font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack {
                Spacer()
                if let stop, !run.finished {
                    Button(stopping ? "멈추는 중…" : "중단", action: stop)
                        .glassAction()
                        .controlSize(.large)
                        .disabled(stopping)
                        .help("지금 지우는 항목을 마친 뒤 멈춥니다. 남은 항목은 지우지 않습니다.")
                }
                Button("완료", action: done)
                    .prominentAction()
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!run.finished)
            }
        }
        .padding(22)
        .frame(width: width)
    }

    private func state(of step: RunStep, at index: Int) -> StepRow.State {
        if let problem = run.problems[step.id] { return .problem(problem) }
        return index < run.done ? .done : index == run.done ? .current : .waiting
    }
}

private struct ProgressRing: View {
    let progress: Double
    let finished: Bool
    let symbol: String

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 6)
            Circle()
                .trim(from: 0, to: max(progress, 0.001))
                .stroke(.green, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: finished ? "checkmark" : symbol)
                .font(.title2.weight(.semibold))
                .foregroundStyle(finished ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: finished)
        }
    }
}

private struct StepRow: View {
    enum State: Equatable {
        case waiting, current, done
        case problem(String)
    }

    let step: RunStep
    let state: State

    var body: some View {
        HStack(spacing: 10) {
            Group {
                switch step.icon {
                case .symbol(let name): Image(systemName: name).foregroundStyle(.secondary)
                case .app(let image): if let image { Image(nsImage: image).resizable() } else { Image(systemName: "app") }
                }
            }
            .frame(width: 20, height: 20)
            Text(step.name).lineLimit(1)
            Spacer(minLength: 8)
            if case .problem(let reason) = state {
                Text(reason).foregroundStyle(.orange).lineLimit(1)
            } else {
                Text(step.amountText).monospacedDigit().foregroundStyle(.secondary)
            }
            ZStack {
                switch state {
                case .done:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).transition(.scale.combined(with: .opacity))
                case .problem:
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).transition(.scale.combined(with: .opacity))
                case .current:
                    ProgressView().controlSize(.small)
                case .waiting:
                    Image(systemName: "circle").foregroundStyle(.quaternary)
                }
            }
            .frame(width: 18)
        }
        .font(.callout)
        .opacity(state == .waiting ? 0.55 : 1)
        .help(state.problemText ?? "")
    }
}

private extension StepRow.State {
    var problemText: String? {
        if case .problem(let reason) = self { return reason }
        return nil
    }
}
