import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("일반", systemImage: "gearshape") }
            CleanupAgesView()
                .tabItem { Label("정리 기준", systemImage: "clock.arrow.circlepath") }
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The menu bar item and updates.
struct GeneralSettingsView: View {
    @Environment(MenuBarSettings.self) private var settings
    @Environment(AppUpdater.self) private var updater

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("메뉴 막대에 Macbak 보기", isOn: $settings.isShown)
            } footer: {
                Text("숨겨도 앱은 계속 실행됩니다. Dock 아이콘을 누르면 창이 다시 열립니다.")
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                Toggle(isOn: $settings.content.pulse) {
                    Label("맥박 (CPU·GPU·메모리 부하)", systemImage: "heart")
                }
                Toggle(isOn: $settings.content.memory) {
                    Label("메모리 사용률", systemImage: "memorychip")
                }
                Toggle(isOn: $settings.content.disk) {
                    Label("디스크 남은 공간", systemImage: "internaldrive")
                }
            } header: {
                Text("보이는 항목")
            } footer: {
                Text("모두 끄면 Macbak 아이콘만 보입니다.")
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(!settings.isShown)

            Section {
                Toggle("숫자", isOn: $settings.content.value)
                Toggle("움직이는 그래프", isOn: $settings.content.graph)
            } header: {
                Text("표시 방식")
            } footer: {
                Text("맥박 그래프는 최근 10초의 박동을 작은 심전도로, 메모리 그래프는 최근 1분을 그리며 2초마다 한 칸씩 움직입니다. 디스크 그래프는 사용량 막대입니다. 둘 다 끄면 항목 아이콘만 보입니다.")
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(!settings.isShown || (!settings.content.pulse && !settings.content.memory && !settings.content.disk))

            Section("미리 보기") {
                MenuBarPreview()
            }
            .opacity(settings.isShown ? 1 : 0.4)

            Section {
                LabeledContent("현재 버전", value: updater.version)
                Toggle("자동으로 확인", isOn: Binding(get: { updater.automaticallyChecks }, set: { updater.setAutomaticallyChecks($0) }))
                Toggle("새 버전을 자동으로 받아 설치",
                       isOn: Binding(get: { updater.automaticallyInstalls }, set: { updater.setAutomaticallyInstalls($0) }))
                    .disabled(!updater.automaticallyChecks)
                Button("지금 확인") { updater.checkNow() }
                    .disabled(!updater.canCheck)
            } header: {
                Text("업데이트")
            } footer: {
                Text(updater.disabledReason ?? (updater.automaticallyChecks
                    ? "하루에 한 번 새 버전을 확인하고, 있으면 설치할지 묻습니다. 업데이트를 확인하고 내려받을 때만 GitHub의 배포 위치에 접속합니다."
                    : "자동 확인이 꺼져 있어 '지금 확인'을 누를 때만 새 버전을 확인합니다. 업데이트를 확인하고 내려받을 때만 GitHub의 배포 위치에 접속합니다."))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(updater.disabledReason != nil)
        }
        .formStyle(.grouped)
    }
}

/// How long each kind of item waits before a clean-up may take it.
struct CleanupAgesView: View {
    @Environment(CleanupSettings.self) private var settings

    var body: some View {
        Form {
            Section {
                ForEach(CleanupAges.Item.allCases, id: \.self) { item in
                    Picker(item.title, selection: Binding(get: { settings.ages[item] }, set: { settings.set(item, $0) })) {
                        ForEach(item.choices, id: \.self) { value in
                            Text("\(value)\(item.unit)").tag(value)
                        }
                    }
                }
            } header: {
                Text("이만큼 쓰지 않은 것만 정리합니다")
            } footer: {
                Text("짧게 고르면 정기 정리와 즉시 정리가 자동으로 지우는 범위도 넓어집니다. 열려 있는 파일과 실행 중인 앱은 기간과 상관없이 지키며, 값을 바꾸면 지금까지의 검사 결과는 다시 검사해야 합니다.")
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                Button("기본값으로") { settings.resetToDefaults() }
                    .disabled(settings.ages == CleanupAges())
            }
        }
        .formStyle(.grouped)
    }
}

/// The live menu bar glyph on a light and a dark strip, with its width.
struct MenuBarPreview: View {
    @Environment(SystemMonitor.self) private var system
    @Environment(MenuBarSettings.self) private var settings

    var body: some View {
        let image = MenuBarGlyph.image(for: settings.content, system: system)
        VStack(alignment: .leading, spacing: 10) {
            // Side by side while the item is narrow; stacked once both strips no longer fit the window (every metric
            // with values and graphs is about 270pt), so the preview cannot widen the whole form past the window.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    strip(image, scheme: .light)
                    strip(image, scheme: .dark)
                }
                VStack(spacing: 8) {
                    strip(image, scheme: .light)
                    strip(image, scheme: .dark)
                }
            }
            Text("폭 \(Int(image.size.width.rounded()))pt. 메뉴 막대가 꽉 차면 아이템이 노치 뒤로 밀려 가려질 수 있어, 좁을수록 잘 보입니다.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .animation(.smooth, value: settings.content)
    }

    private func strip(_ image: NSImage, scheme: ColorScheme) -> some View {
        Image(nsImage: image)
            .renderingMode(.template)
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.background))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator))
            .environment(\.colorScheme, scheme)
            .accessibilityHidden(true)
    }
}
