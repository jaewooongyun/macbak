import SwiftUI

struct AIStorageScreen: View {
    @Environment(AIStorage.self) private var storage
    @Environment(AIMonitor.self) private var monitor

    var body: some View {
        CleanupBoard(
            candidates: storage.report?.candidates ?? [],
            title: "정리 후보",
            note: "실제 폴더를 검사해 크기와 판정을 보여 줍니다. 정리한 파일은 되돌릴 수 없고, 대화 기록은 표시만 합니다. 끝난 작업 임시 파일은 디스크 화면의 '프로젝트까지 검사'에서 골라 지울 수 있습니다.",
            onFinished: { Task { await storage.scan(using: monitor) } }
        ) { _ in
            summaryCard
        }
        .task {
            if storage.isStale { await storage.scan(using: monitor) }
        }
    }

    private var summaryCard: some View {
        Card {
            CardHeader("AI 데이터", symbol: Screen.aiStorage.symbol) {
                if storage.scanning {
                    ProgressView().controlSize(.small)
                    Text("검사하는 중…").font(.callout).foregroundStyle(.secondary)
                } else {
                    Button("다시 검사") { Task { await storage.scan(using: monitor) } }
                        .glassAction()
                }
            }
            if let report = storage.report {
                let total = report.totals.reduce(0) { $0 + $1.bytes }
                let partial = report.totals.contains(where: \.partial)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text((partial ? "≥ " : "") + total.diskText).font(Theme.numeral(40)).monospacedDigit()
                    Text("AI 도구가 쓰는 공간").font(.title3).foregroundStyle(.secondary)
                }
                SegmentBar(segments: report.totals.map { BarSegment($0.id, Double($0.bytes), $0.tint) }, height: 22)
                AdaptiveGrid(minimumColumnWidth: 220, maximumColumns: 3, spacing: 12, fillsRows: false) {
                    ForEach(report.totals) { total in
                        LegendRow(total.tint, title: total.name, value: (total.partial ? "≥ " : "") + total.bytes.diskText,
                                  note: total.vendor?.name ?? "여러 도구가 함께 씀")
                    }
                }
                Text("검사 \(report.scannedAt.formatted(.relative(presentation: .named))) · \(report.duration.formatted(.number.precision(.fractionLength(1))))초 걸림 · 색은 제조사")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("AI 도구 폴더의 크기를 재고 있습니다. 파일 이름·크기·날짜만 읽습니다.").font(.body).foregroundStyle(.secondary)
            }
        }
    }
}
