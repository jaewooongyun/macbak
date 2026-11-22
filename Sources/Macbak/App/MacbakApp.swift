import SwiftUI

@main
enum Entry {
    /// `--snapshot <dir>` renders every screen to PNG in light and dark, then exits; `--scan-report` prints a read-only scan.
    @MainActor static func main() {
        let args = CommandLine.arguments
        if let flag = args.firstIndex(of: "--snapshot") {
            let dir = args.indices.contains(flag + 1) ? args[flag + 1] : "snapshots"
            SnapshotRunner.run(outputDirectory: URL(fileURLWithPath: dir))
        } else if args.contains("--scan-report") {
            ScanReport.run()
        } else {
            MacbakApp.main()
        }
    }
}

/// Opens the main window from places with no SwiftUI environment, such as the app delegate.
/// - Important: SwiftUI has no API for this, so the action is captured by the first view that appears: the main window,
///   or the menu bar item when the app starts with its window closed.
@MainActor
enum MainWindow {
    static var open: OpenWindowAction?

    /// Whether a window showing live data is on screen: not closed, minimized or fully covered by other windows.
    /// Monitors that only feed the window pause otherwise.
    static var isOnScreen: Bool {
        NSApp.windows.contains { $0.isVisible && $0.occlusionState.contains(.visible) && $0.styleMask.contains(.titled) && !($0 is NSPanel) }
    }
}

/// A screen asked for from outside the main window, as by the menu bar's deep clean-up. The window takes it and clears
/// it, whether it was already open or opens for it.
@MainActor
@Observable
final class AppNavigation {
    var requested: Screen?
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// - Important: With the menu bar item hidden, SwiftUI otherwise quits the app when the last window closes,
    ///   which silently stops monitoring and the scheduled loop.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// A Dock click with no window open brings the main window back; a `Window` scene does not do this by itself.
    /// - Important: Checks the main window itself rather than `hasVisibleWindows`, which can count the menu bar item and
    ///   then leave the app with no window to show.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated {
            if !MainWindow.isOnScreen {
                MainWindow.open?(id: "main")
                NSApp.activate()
            }
        }
        return true
    }
}

struct MacbakApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var system: SystemMonitor
    @State private var loop: LoopScheduler
    @State private var ai: AIMonitor
    @State private var aiStorage: AIStorage
    @State private var cleanup: CleanupCoordinator
    @State private var runner: CleanupRunner
    @State private var menuBar = MenuBarSettings()
    @State private var navigation: AppNavigation

    init() {
        // Started here, not in a view, so monitoring and the loop keep running with the window closed.
        // The menu bar panel shows the app list and AI use too, so it counts as a window here.
        let system = SystemMonitor(isWindowShown: { MainWindow.isOnScreen || MenuBarPanel.isOpen })
        let ai = AIMonitor(isWindowShown: { MainWindow.isOnScreen || MenuBarPanel.isOpen })
        let cleanup = CleanupCoordinator()
        let storage = AIStorage()
        // Both clean-up screens and the loop hand rows to one runner, which checks each against these lists again
        // before deleting, and never overlaps a disk scan. The AI storage scan (most of a minute) is not waited for; it
        // starts no new reading while a run deletes, and drops what was deleted meanwhile when its report lands.
        let runner = CleanupRunner(latest: { id in (cleanup.all + (storage.report?.candidates ?? [])).first { $0.id == id } },
                                   settle: { await cleanup.settled() },
                                   forget: { ids in
                                       cleanup.forget(ids)
                                       storage.forget(ids)
                                   })
        cleanup.isDeleting = { [weak runner] in runner?.isRunning ?? false }
        storage.isDeleting = { [weak runner] in runner?.isRunning ?? false }
        // A scheduled run scans for real, lets the on-device model decide the app caches it holds, then deletes the
        // shallow set. With no window or panel open the AI monitor is paused, so AI caches cannot be told unused and
        // stay out — the safe side.
        let loop = LoopScheduler(system: system, cleans: true, scan: {
            await cleanup.scan()
            await cleanup.explored()
            await ai.wake()
            await storage.scan(using: ai)
            guard cleanup.scannedAt != nil,
                  let deleted = await runner.runShallow(cleanup.all + (storage.report?.candidates ?? [])) else { return nil }
            return (deleted.count, deleted.reduce(0) { $0 + $1.bytes })
        })
        system.start()
        loop.start()
        ai.start()
        _system = State(initialValue: system)
        _loop = State(initialValue: loop)
        _ai = State(initialValue: ai)
        _cleanup = State(initialValue: cleanup)
        _aiStorage = State(initialValue: storage)
        _runner = State(initialValue: runner)
        // For measurements: `MACBAK_OPEN_SCREEN=disk` opens the main window on that screen, as the menu bar's link does.
        let navigation = AppNavigation()
        navigation.requested = ProcessInfo.processInfo.environment["MACBAK_OPEN_SCREEN"].flatMap(Screen.init(rawValue:))
        _navigation = State(initialValue: navigation)
    }

    var body: some Scene {
        Window("Macbak", id: "main") {
            ContentView()
                .environment(system)
                .environment(loop)
                .environment(ai)
                .environment(aiStorage)
                .environment(cleanup)
                .environment(runner)
                .environment(navigation)
                .frame(minWidth: 760, minHeight: 560)
        }
        .defaultSize(width: 1180, height: 800)
        .commands {
            SidebarCommands()
            CommandGroup(after: .toolbar) {
                Button("새로 고침") { system.refreshAll() }
                    .keyboardShortcut("r")
            }
        }

        MenuBarExtra(isInserted: Binding(get: { menuBar.isShown }, set: { menuBar.isShown = $0 })) {
            MenuBarPanel()
                .environment(system)
                .environment(loop)
                .environment(ai)
                .environment(aiStorage)
                .environment(cleanup)
                .environment(runner)
                .environment(navigation)
        } label: {
            MenuBarLabel()
                .environment(system)
                .environment(menuBar)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(system)
                .environment(menuBar)
        }
    }
}
