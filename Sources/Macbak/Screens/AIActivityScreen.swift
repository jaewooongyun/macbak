import Charts
import SwiftUI

/// AI tools by vendor: live CPU stacked by vendor, one card per vendor with its tools' sessions and jobs, then the processes.
/// Everything here comes from `AITool.catalog`, so a new tool shows up without touching this file.
struct AIActivityScreen: View {
    @Environment(AIMonitor.self) private var monitor

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.gutter) {
                nowCard.riseIn(0)
                LiquidGrid(minimumColumnWidth: 300, maximumColumns: 3) {
                    ForEach(visibleVendors, id: \.self) { vendor in
                        VendorCard(vendor: vendor, tools: tools(of: vendor))
                    }
                }
                .riseIn(1)
                processesCard.riseIn(2)
                Label("프로세스는 이름과 경로만, 세션은 파일 이름과 수정 시각만, 작업은 상태 값만 읽습니다. 대화 내용은 읽지 않습니다.", systemImage: "lock")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .readableColumn()
        }
    }

    /// A tool is worth a row when it runs, or has left logs or jobs behind.
    private func isVisible(_ tool: AITool) -> Bool {
        monitor.usage(of: tool) != nil || (monitor.activity?.sessions[tool.id]?.logs ?? 0) > 0 || monitor.activity?.jobs[tool.id] != nil
    }

    private func tools(of vendor: AIVendor) -> [AITool] {
        AITool.catalog.filter { $0.vendor == vendor && isVisible($0) }
    }

    private var visibleVendors: [AIVendor] {
        AIVendor.allCases.filter { !tools(of: $0).isEmpty }
    }

    private var nowCard: some View {
        Card {
            CardHeader("지금 AI", symbol: "waveform") {
                Freshness(date: monitor.processSampledAt, cadence: "2초마다")
            }
            AdaptiveGrid(minimumColumnWidth: 130, maximumColumns: 4, spacing: 12) {
                MetricView(value: "\(monitor.tools.count)개", caption: "실행 중인 도구")
                MetricView(value: "\(monitor.totalSessions)개", caption: "세션")
                MetricView(value: monitor.totalCPU.percentText, caption: "CPU · 코어 1개 = 100%")
                MetricView(value: monitor.totalMemory.memoryText, caption: "메모리")
            }
            VendorCPUChart().frame(height: 140)
        }
    }

    private var processesCard: some View {
        Card {
            CardHeader("실행 중인 프로세스", symbol: "square.stack.3d.up") {
                Text("메모리 많은 순").font(.callout).foregroundStyle(.secondary)
            }
            if monitor.tools.isEmpty {
                Text(monitor.processSampledAt == nil ? "프로세스를 읽는 중입니다." : "실행 중인 AI 도구가 없습니다.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            } else {
                let largest = Double(monitor.tools.map(\.memory).max() ?? 1)
                VStack(spacing: 12) {
                    ForEach(monitor.tools) { usage in
                        AIToolRow(usage: usage, largest: largest, cpuHistory: monitor.history.map { $0.cpuByTool[usage.tool.id] ?? 0 },
                                  sampleID: monitor.history.last?.id ?? 0)
                    }
                }
                // Animate tools appearing, leaving or reordering; per-sample memory changes would keep rows moving.
                .animation(.smooth, value: monitor.tools.map(\.id))
            }
        }
    }
}

private struct VendorCard: View {
    let vendor: AIVendor
    let tools: [AITool]
    @Environment(AIMonitor.self) private var monitor

    var body: some View {
        let running = tools.filter { monitor.usage(of: $0) != nil }.count
        Card {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(vendor.tint).frame(width: 10, height: 10)
                Text(vendor.name).font(.headline)
                Spacer(minLength: 8)
                Text(running > 0 ? "\(running)개 실행 중" : "실행 중 아님").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(tools) { tool in
                ToolActivity(tool: tool)
                if tool.id != tools.last?.id { Divider() }
            }
        }
    }
}

private struct ToolActivity: View {
    let tool: AITool
    @Environment(AIMonitor.self) private var monitor

    var body: some View {
        let usage = monitor.usage(of: tool)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: tool.symbol).foregroundStyle(.secondary).frame(width: 20)
                Text(tool.name).font(.body.weight(.semibold))
                Spacer(minLength: 8)
                if let usage {
                    StatusTag(title: usage.sessions > 0 ? "세션 \(usage.sessions)개" : "실행 중", symbol: "circle.fill", tint: .green)
                        .font(.callout)
                        .imageScale(.small)
                } else {
                    Text("꺼짐").font(.callout).foregroundStyle(.secondary)
                }
            }
            if let stats = monitor.activity?.sessions[tool.id] {
                ActivityLadder(stats: stats, tint: tool.vendor.tint)
                Text(logSummary(stats)).font(.callout).foregroundStyle(.secondary)
            }
            if let jobs = monitor.activity?.jobs[tool.id] {
                HStack(spacing: 14) {
                    Text("백그라운드 작업").foregroundStyle(.secondary)
                    LegendDot(color: .green, text: "실행 \(jobs.running)")
                    if jobs.waiting > 0 {
                        LegendDot(color: .yellow, text: "대기 \(jobs.waiting)").help("입력이나 사용량 한도를 기다리는 작업")
                    }
                    LegendDot(color: .gray, text: "끝남 \(jobs.finished)")
                    if jobs.unknown > 0 {
                        LegendDot(color: .orange, text: "모름 \(jobs.unknown)").help("state.json이 없거나 읽을 수 없는 작업 · 0으로 세지 않음")
                    }
                }
                .font(.callout)
            }
        }
    }

    private func logSummary(_ stats: SessionStats) -> String {
        var parts = ["대화 \(stats.logs)개"]
        if stats.projects > 0 { parts.append("프로젝트 \(stats.projects)개") }
        if stats.nestedLogs > 0 { parts.append("하위 에이전트 기록 \(stats.nestedLogs)개") }
        return parts.joined(separator: " · ")
    }
}

private struct LegendDot: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).monospacedDigit()
        }
    }
}

/// Conversations updated within 5 minutes, an hour, a day and a week, as four bars on one scale (the week's count).
private struct ActivityLadder: View {
    let stats: SessionStats
    let tint: Color

    var body: some View {
        let steps = [("5분", stats.within5m), ("1시간", stats.within1h), ("24시간", stats.within24h), ("7일", stats.within7d)]
        let top = Double(max(stats.within7d, 1))
        HStack(alignment: .bottom, spacing: 10) {
            ForEach(steps, id: \.0) { label, count in
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(count > 0 ? AnyShapeStyle(tint) : AnyShapeStyle(.quaternary))
                        .frame(height: max(3, 34 * Double(count) / top))
                        .frame(height: 34, alignment: .bottom)
                    Text("\(count)").font(Theme.numeral(15)).monospacedDigit().contentTransition(.numericText())
                    Text(label).font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("최근 갱신된 대화")
        .accessibilityValue(steps.map { "\($0.0) 안 \($0.1)개" }.joined(separator: ", "))
    }
}

struct AIToolRow: View {
    let usage: AIToolUsage
    let largest: Double
    let cpuHistory: [Double]
    let sampleID: Int

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(usage.tool.vendor.tint).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(usage.tool.name).font(.body.weight(.medium)).lineLimit(1)
                Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(minWidth: 140, maxWidth: 220, alignment: .leading)
            Sparkline(values: cpuHistory, sampleID: sampleID, capacity: AIMonitor.historyCapacity, tint: usage.tool.vendor.tint)
                .frame(width: 96, height: 24)
                .help("최근 2분 CPU")
            MeterBar(fraction: Double(usage.memory) / max(largest, 1), tint: usage.tool.vendor.tint)
            Text(usage.memory.memoryText)
                .font(.body.monospacedDigit())
                .frame(width: 76, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        var parts = ["프로세스 \(usage.processes)개"]
        if usage.sessions > 0 { parts.append("세션 \(usage.sessions)개") }
        parts.append("CPU " + usage.cpu.percentText)
        return parts.joined(separator: " · ")
    }
}

/// AI CPU over the last two minutes, stacked by vendor. It steps once per sample instead of scrolling.
struct VendorCPUChart: View {
    @Environment(AIMonitor.self) private var monitor

    var body: some View {
        let history = monitor.history
        let vendors = AIVendor.allCases.filter { vendor in history.contains { $0.cpu(of: vendor) > 0.05 } }
        let last = history.last?.id ?? 0
        let ceiling = max(100, (history.map(\.cpu).max() ?? 0) * 1.2)
        VStack(alignment: .leading, spacing: 8) {
            Chart {
                ForEach(vendors, id: \.self) { vendor in
                    ForEach(history) { sample in
                        AreaMark(x: .value("시점", sample.id), y: .value("CPU", sample.cpu(of: vendor)), stacking: .standard)
                            .foregroundStyle(by: .value("제조사", vendor.name))
                            .interpolationMethod(.monotone)
                    }
                }
            }
            .chartForegroundStyleScale(domain: vendors.map(\.name), range: vendors.map(\.tint))
            .chartLegend(.hidden)
            .chartXScale(domain: (last - AIMonitor.historyCapacity + 1)...max(last, 1))
            .chartYScale(domain: 0...ceiling)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let cpu = value.as(Double.self) { Text(cpu.percentText).font(.callout) }
                    }
                }
            }
            HStack(spacing: 14) {
                ForEach(vendors, id: \.self) { vendor in
                    LegendDot(color: vendor.tint, text: vendor.name)
                }
                Spacer()
                Text("최근 2분").foregroundStyle(.secondary)
            }
            .font(.callout)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("제조사별 AI CPU 사용량 변화")
        .accessibilityValue("현재 \(monitor.totalCPU.percentText)")
    }
}
