import AppKit
import SwiftUI

/// The on-device model's progress over the rows the rules could not tell. Shown only while it has something to say.
/// - Note: The moving part is the small glyph alone, played by Core Animation, so the card is not redrawn while it
///   pulses; reduce motion stops it.
struct ExploreCard: View {
    let phase: CacheExplorer.Phase

    var body: some View {
        Card {
            HStack(alignment: .center, spacing: 14) {
                ExploreGlyph(active: isExploring)
                    .frame(width: 36, height: 36)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if case .exploring(let done, let total, _) = phase {
                    Text("\(done)/\(total)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if case .exploring(let done, let total, _) = phase {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                    .progressViewStyle(.linear)
                    .accessibilityLabel("기기 AI 탐지 진행")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var isExploring: Bool {
        if case .exploring = phase { true } else { false }
    }

    private var title: String {
        switch phase {
        case .idle: ""
        case .exploring: "기기 AI가 살펴보는 중"
        case .unavailable: "기기 AI를 쓰지 않았습니다"
        case .finished(_, let offered, _): offered > 0 ? "기기 AI가 \(offered)개를 더 찾았습니다" : "기기 AI가 살펴봤습니다"
        }
    }

    private var detail: String {
        switch phase {
        case .idle: ""
        case .exploring(_, _, let current):
            "코드 규칙으로 판단하지 못한 캐시 위치의 항목을 하나씩 봅니다. 파일 내용은 열지 않습니다 · ~/\(current)"
        case .unavailable(let reason): reason
        case .finished(let looked, let offered, let kept):
            [
                "\(looked)개를 봤습니다.",
                offered > 0 ? "\(offered)개를 \"\(CleanupStatus.review.title)\"에 더했고, 미리 고르지는 않습니다." : nil,
                kept > 0 ? "\(kept)개는 사용자 데이터나 설정으로 보여 \"\(CleanupStatus.protected.title)\"으로 지켰습니다." : nil,
                offered == 0 && kept == 0 ? "규칙대로 둡니다." : nil,
            ].compactMap(\.self).joined(separator: " ")
        }
    }
}

/// The explorer's mark: a magnifying glass that pulses while the model looks, sparkles once it is done.
/// - Important: Not `.symbolEffect(.pulse, options: .repeating)`: like the effects `Beat` replaced, that redraws the whole
///   card on the CPU every frame, for as long as the model looks. A repeating layer animation is played by the render server.
struct ExploreGlyph: NSViewRepresentable {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> ExploreGlyphView { ExploreGlyphView() }

    func updateNSView(_ view: ExploreGlyphView, context: Context) {
        view.show(active: active, pulsing: active && !reduceMotion)
    }
}

final class ExploreGlyphView: NSView {
    private let mark = CALayer()
    private var active = false
    private var pulsing = false

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        mark.contentsGravity = .center
        layer?.addSublayer(mark)
        setAccessibilityElement(false)
        paint()
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        mark.contentsScale = window?.backingScaleFactor ?? 2
    }

    /// A layer leaving the window can lose its animations, so the pulse is put back when it returns.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyPulse()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mark.frame = bounds
        CATransaction.commit()
    }

    func show(active: Bool, pulsing: Bool) {
        if active != self.active {
            self.active = active
            paint()
        }
        if pulsing != self.pulsing {
            self.pulsing = pulsing
            applyPulse()
        }
    }

    private func applyPulse() {
        guard pulsing else {
            mark.removeAnimation(forKey: "pulse")
            return
        }
        guard mark.animation(forKey: "pulse") == nil else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.3
        pulse.duration = 0.9
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        mark.add(pulse, forKey: "pulse")
    }

    private func paint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let config = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.secondaryLabelColor]))
            mark.contents = NSImage(systemSymbolName: active ? "sparkle.magnifyingglass" : "sparkles", accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
        }
    }
}

/// Marks a row the on-device model offered, as opposed to the rules. Plain, in keeping with the app.
struct AIBadge: View {
    var body: some View {
        Label("기기 AI 추정", systemImage: "sparkles")
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(.quaternary))
            .help("코드 규칙이 아니라 기기 AI가 이름·크기·날짜를 보고 판단한 항목입니다. 기기 AI는 미리 체크하지 않습니다.")
    }
}

/// A tool's own clean-up command, with a copy button: some tools ask not to have their cache deleted file by file.
struct CommandChip: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal").foregroundStyle(.secondary)
            Text(command).font(.callout.monospaced()).textSelection(.enabled).lineLimit(1)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderless)
            .help(copied ? "복사했습니다" : "명령 복사")
            .accessibilityLabel("명령 복사")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.quaternary.opacity(0.6)))
        .padding(.top, 2)
    }
}
