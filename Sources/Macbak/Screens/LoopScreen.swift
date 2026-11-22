import SwiftUI

struct LoopScreen: View {
    @Environment(LoopScheduler.self) private var loop
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var loop = loop
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.gutter) {
                Card {
                    CardHeader("정기 정리", symbol: "clock.arrow.circlepath") {
                        Toggle("정기 정리", isOn: $loop.enabled)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                    Text("정해진 시각마다 이 Mac을 검사하고 얕은 정리를 합니다. 규칙이 다시 생긴다고 확인한 캐시만 지우고, 골라서 지울 것과 지우면 안 되는 것은 건드리지 않습니다. 지우기 직전 검사는 직접 누를 때와 같습니다.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                        GridRow {
                            Text("시각").font(.body)
                            DatePicker("시각", selection: timeBinding, displayedComponents: .hourAndMinute)
                                .labelsHidden()
                                .fixedSize()
                        }
                        GridRow {
                            Text("반복").font(.body)
                            Picker("반복", selection: $loop.schedule.weekdaysOnly) {
                                Text("매일").tag(false)
                                Text("평일만").tag(true)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                    .disabled(!loop.enabled)
                    StatusTag(title: nextRunText, symbol: loop.enabled ? "calendar.badge.clock" : "pause.circle", tint: .secondary)
                        .font(.body)
                        .contentTransition(.numericText())
                        .animation(reduceMotion ? nil : .smooth, value: nextRunText)
                    Text("앱이 실행 중인 동안 동작합니다. 창을 닫거나 메뉴 막대에서 숨겨도 계속 실행되고, 앱을 종료하면 멈춥니다. Mac이 잠들어 놓친 점검은 깨어난 뒤 한 번만 실행합니다.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Divider()
                    Toggle("로그인할 때 Macbak 열기", isOn: loginBinding)
                        .font(.body)
                    if let error = loop.loginItemError {
                        Text("로그인 항목을 바꾸지 못했습니다: \(error)").font(.callout).foregroundStyle(.secondary)
                    } else if loop.loginItemStatus == .requiresApproval {
                        Text("시스템 설정 → 일반 → 로그인 항목에서 허용해 주세요.").font(.callout).foregroundStyle(.secondary)
                    }
                }
                .riseIn(0)

                Card {
                    CardHeader("점검 기록", symbol: "list.bullet.rectangle") {
                        Button("기록 지우기") {
                            withAnimation(reduceMotion ? nil : .smooth) { loop.clearHistory() }
                        }
                        .glassAction()
                        .disabled(loop.history.isEmpty)
                        Button(loop.isChecking ? "정리 중…" : "지금 정리") {
                            withAnimation(reduceMotion ? nil : .snappy) { loop.run(.manual) }
                        }
                        .prominentAction()
                        .disabled(loop.isChecking)
                    }
                    if loop.history.isEmpty {
                        Text("아직 점검한 기록이 없습니다.").font(.body).foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(loop.history) { run in
                                LoopRunRow(run: run)
                                    .transition(.move(edge: .top).combined(with: .opacity))
                                if run.id != loop.history.last?.id { Divider() }
                            }
                        }
                    }
                }
                .riseIn(1)
            }
            .readableColumn()
        }
    }

    private var nextRunText: String {
        guard let next = loop.nextRun else { return "정기 정리가 꺼져 있습니다" }
        let when = next.formatted(.dateTime.month().day().weekday(.abbreviated).hour().minute())
        return "다음 정리 \(when) · \(next.formatted(.relative(presentation: .numeric)))"
    }

    private var timeBinding: Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: loop.schedule.hour, minute: loop.schedule.minute, second: 0, of: .now) ?? .now },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                loop.schedule.hour = parts.hour ?? loop.schedule.hour
                loop.schedule.minute = parts.minute ?? loop.schedule.minute
            }
        )
    }

    private var loginBinding: Binding<Bool> {
        Binding(get: { loop.loginItemStatus == .enabled }, set: { loop.setLaunchAtLogin($0) })
    }
}

struct LoopRunRow: View {
    let run: LoopRun

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(run.date.formatted(.dateTime.month().day().hour().minute())).font(.body.weight(.medium)).monospacedDigit()
                    Text(run.trigger == .scheduled ? "예약" : "직접")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .background(Capsule().strokeBorder(.separator))
                }
                Text(summary).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            VStack(alignment: .trailing, spacing: 3) {
                Text(run.hasAmount ? run.readyBytes.diskText : "–").font(.body.monospacedDigit())
                Text(run.readySummary).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 10)
    }

    private var summary: String {
        var parts: [String] = []
        if let disk = run.diskAvailable { parts.append("디스크 \(disk.diskText) 사용 가능") }
        if let used = run.memoryUsed, let physical = run.memoryPhysical { parts.append("메모리 \(used.memoryText) / \(physical.memoryText)") }
        if let pressure = run.pressure.flatMap(MemoryPressure.init(rawValue:)) { parts.append(pressure.title) }
        return parts.joined(separator: " · ")
    }
}

