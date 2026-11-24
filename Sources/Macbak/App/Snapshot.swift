import AppKit
import SwiftUI

/// Renders each screen offscreen in light and dark so layout and legibility can be checked without a display.
/// - Note: High-contrast appearances render identically to light offscreen, so Increase Contrast is not covered here.
@MainActor
enum SnapshotRunner {
    static func run(outputDirectory: URL) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        // A fast cadence fills the chart with real samples before the first render.
        let system = SystemMonitor(interval: .milliseconds(200))
        system.start()
        spin(4)
        system.stop()  // freeze values so numbers are not caught mid-transition

        // In-memory loop with two example runs; the user's real settings and history are not read or written.
        let loop = LoopScheduler(system: system, defaults: nil, cleans: true, scan: { (3, 1_850_000_000) })
        loop.enabled = true
        loop.run(.scheduled, at: Date.now.addingTimeInterval(-86_400))
        spin(0.2)  // one check at a time: the first records before the second starts
        loop.run(.manual)

        // Real AI data: sample processes for a few seconds, then scan storage once and wait for it (read-only).
        let ai = AIMonitor(interval: .milliseconds(300))
        ai.start()
        spin(4)
        let aiStorage = AIStorage()
        let scanStarted = Date.now
        Task { await aiStorage.scan(using: ai) }
        while aiStorage.report == nil, Date.now.timeIntervalSince(scanStarted) < 90 { spin(0.5) }
        ai.stop()
        print("ai storage scan:", aiStorage.report.map { String(format: "%.1fs, %d candidates", $0.duration, $0.candidates.count) } ?? "timed out")
        for candidate in aiStorage.report?.candidates ?? [] {
            print("  \(candidate.verdict.status)\t\(candidate.bytes.diskText)\t\(candidate.id)")
        }
        print("  tools:", ai.tools.map { "\($0.tool.name) p\($0.processes) s\($0.sessions)" }.joined(separator: ", "))

        // Fixture candidates: rendering must never scan or touch the real clean-up targets.
        let cleanup = CleanupCoordinator(fixture: [.xcode: CleanupCandidate.samples, .general: CleanupCandidate.generalSamples],
                                         explorer: CacheExplorer(fixture: .exploring(done: 2, total: 4, current: ".cache/codex-runtimes")))

        let looks: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]
        // Default size plus the window's minimum and a wide window, to check how layouts respond to width.
        let sizes: [(String, NSSize)] = [("", NSSize(width: 1180, height: 800)), ("-min", NSSize(width: 760, height: 560)), ("-wide", NSSize(width: 1680, height: 1000))]
        var failures = 0
        for (name, look) in looks {
            for screen in Screen.allCases {
                for (suffix, size) in sizes where suffix.isEmpty || name == "light" {
                    let view = ContentView(selection: screen).environment(system).environment(loop).environment(ai).environment(aiStorage)
                        .environment(cleanup).environment(CleanupRunner()).environment(AppNavigation())
                    failures += render(view, size: size, look: look, to: outputDirectory.appendingPathComponent("\(screen.rawValue)-\(name)\(suffix).png"))
                }
                // The clean-up groups sit below the fold; a tall render shows all of them at once.
                if screen == .disk {
                    let view = ContentView(selection: screen).environment(system).environment(loop).environment(ai).environment(aiStorage)
                        .environment(cleanup).environment(CleanupRunner()).environment(AppNavigation())
                    failures += render(view, size: NSSize(width: 1180, height: 3600), look: look, to: outputDirectory.appendingPathComponent("disk-\(name)-tall.png"))
                    // The narrowest window too, where the folded group's icons must still sit on the list rows' column.
                    if name == "light" {
                        failures += render(view, size: NSSize(width: 760, height: 3600), look: look, to: outputDirectory.appendingPathComponent("disk-light-min-tall.png"))
                    }
                }
            }
            // .zero = size to fit, the way the real menu bar panel sizes itself (a fixed height hid a truncation bug).
            let panel = MenuBarPanel().environment(system).environment(loop).environment(ai).environment(aiStorage).environment(cleanup).environment(CleanupRunner()).environment(AppNavigation())
            failures += render(panel, size: .zero, look: look, to: outputDirectory.appendingPathComponent("menubar-\(name).png"))
            // Rendered from inside the built app, whose bundle would turn a real updater on; this one never starts.
            let updater = AppUpdater.disabled(reason: "미리 보기에서는 업데이트를 확인하지 않습니다.")
            let settings = SettingsView().environment(system).environment(MenuBarSettings(defaults: nil)).environment(updater)
                .environment(CleanupSettings(defaults: nil))
            failures += render(settings, size: .zero, look: look, to: outputDirectory.appendingPathComponent("settings-\(name).png"))
            // Everything on: the widest menu bar item, whose preview once overflowed the settings window.
            let everything = MenuBarSettings(defaults: nil)
            everything.content = MenuBarContent(pulse: true, memory: true, disk: true, value: true, graph: true)
            failures += render(SettingsView().environment(system).environment(everything).environment(updater)
                .environment(CleanupSettings(defaults: nil)), size: .zero, look: look,
                               to: outputDirectory.appendingPathComponent("settings-all-\(name).png"))
            // A clean-up part way, as the menu bar panel shows it, with its stop button.
            var going = RunProgress(steps: (1...3).map { RunStep(id: "\($0)", name: "app-\($0) (Xcode)", icon: .symbol("hammer"), amount: 4.9e9, amountText: "4.9 GB") })
            going.done = 1
            failures += render(RunPanel(run: going, wording: .cleanup, total: { Int64($0).diskText }, done: {}, stop: {}, width: 312, visibleSteps: 4),
                               size: .zero, look: look, to: outputDirectory.appendingPathComponent("runpanel-stop-\(name).png"))
            failures += render(GlyphCatalog(system: system), size: .zero, look: look, to: outputDirectory.appendingPathComponent("glyphs-\(name).png"))
            failures += render(PulseExamples(), size: .zero, look: look, to: outputDirectory.appendingPathComponent("pulse-examples-\(name).png"))
        }
        exit(failures == 0 ? 0 : 1)
    }

    /// Returns 1 on failure so callers can count.
    private static func render<V: View>(_ view: V, size: NSSize, look: NSAppearance.Name, to url: URL) -> Int {
        // Offscreen there is no window-server backdrop; vibrant fills blended over transparency come out wrong.
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        host.frame = NSRect(origin: .zero, size: size == .zero ? host.fittingSize : size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: look)
        window.contentView = host
        spin(2)  // let entrance animations settle
        defer { window.close() }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return 1 }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]), (try? png.write(to: url)) != nil else { return 1 }
        print(url.path)
        return 0
    }

    /// The panel's pulse row with example samples at the edges, at the width the panel gives it: memory leading at 100%
    /// under critical pressure, no GPU reading, and no sample yet.
    private struct PulseExamples: View {
        private static let examples: [(String, VitalSample?, MemoryPressure?)] = [
            ("메모리 선두 100%", VitalSample(id: 1, cpu: 0.99, gpu: 0.98, memory: 1, memoryLevel: .critical), .critical),
            ("GPU 없음", VitalSample(id: 2, cpu: 0.12, gpu: nil, memory: 0.45, memoryLevel: .normal), .normal),
            ("샘플 없음", nil, nil),
        ]

        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Self.examples, id: \.0) { title, sample, pressure in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.caption).foregroundStyle(.tertiary)
                        HStack(alignment: .center, spacing: 12) {
                            ConcentricVitalRings(vitals: sample.map { [$0] } ?? [], pressure: pressure)
                            VitalReadouts(sample: sample, pressure: pressure)
                        }
                        .frame(width: 288, alignment: .leading)
                    }
                }
            }
            .padding(20)
        }
    }

    /// Every menu bar combination on a light and a dark strip, with its width — the menu bar itself cannot be captured.
    private struct GlyphCatalog: View {
        let system: SystemMonitor

        private static let cases: [(String, MenuBarContent)] = [
            ("맥박 숫자", MenuBarContent(pulse: true, memory: false, disk: false, value: true, graph: false)),
            ("맥박 아이콘만", MenuBarContent(pulse: true, memory: false, disk: false, value: false, graph: false)),
            ("맥박+메모리 숫자", MenuBarContent(pulse: true, memory: true, disk: false, value: true, graph: false)),
            ("메모리 숫자 (기본)", MenuBarContent(memory: true, disk: false, value: true, graph: false)),
            ("메모리 그래프", MenuBarContent(memory: true, disk: false, value: false, graph: true)),
            ("메모리 숫자+그래프", MenuBarContent(memory: true, disk: false, value: true, graph: true)),
            ("디스크 숫자", MenuBarContent(memory: false, disk: true, value: true, graph: false)),
            ("디스크 그래프", MenuBarContent(memory: false, disk: true, value: false, graph: true)),
            ("둘 다 숫자", MenuBarContent(memory: true, disk: true, value: true, graph: false)),
            ("둘 다 숫자+그래프", MenuBarContent(memory: true, disk: true, value: true, graph: true)),
            ("아이콘만", MenuBarContent(memory: true, disk: true, value: false, graph: false)),
            ("항목 없음", MenuBarContent(memory: false, disk: false, value: true, graph: false)),
        ]

        var body: some View {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                ForEach(Self.cases, id: \.0) { title, content in
                    let image = MenuBarGlyph.image(for: content, system: system)
                    GridRow {
                        Text(title).font(.body)
                        strip(image, .light)
                        strip(image, .dark)
                        Text("\(Int(image.size.width.rounded()))pt").font(.body.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(20)
        }

        private func strip(_ image: NSImage, _ scheme: ColorScheme) -> some View {
            Image(nsImage: image)
                .renderingMode(.template)
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .frame(width: 190, height: 24, alignment: .leading)
                .background(.background)
                .environment(\.colorScheme, scheme)
        }
    }

    private static func spin(_ seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}
