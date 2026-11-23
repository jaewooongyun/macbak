import Darwin
import Foundation
import Testing
@testable import Macbak

/// Developer tools left running after their terminal or parent tool went away: found only under developer tool
/// locations, never a service, an app or anything that could not be read, and ended with SIGTERM only after one more check.
@Suite struct OrphanProcessTests {
    static let home = "/Users/someone"
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let node = home + "/.nvm/versions/node/v22.1.0/bin/node"

    static func entry(_ pid: pid_t, path: String? = node, ppid: pid_t? = 1, pgid: pid_t? = 500, uid: uid_t? = getuid(),
                      age: TimeInterval? = 3600, footprint: UInt64? = 1_000) -> ProcessSnapshot.Entry {
        ProcessSnapshot.Entry(pid: pid, ppid: ppid, pgid: pgid, uid: uid, path: path, start: age.map { now.addingTimeInterval(-$0) }, footprint: footprint, cpu: 0)
    }

    /// One orphaned node tool (pid 100) among processes that must each be left alone for one reason.
    static let crowd: [ProcessSnapshot.Entry] = [
        entry(100),
        entry(101, path: "/Applications/Xcode.app/Contents/Developer/usr/bin/crashreporter"),   // inside running Xcode
        entry(102, pgid: 102),                                                                 // leads its group, like tmux
        entry(103),                                                                            // a launchd service
        entry(104, path: "/usr/bin/ssh-agent"),                                                // a system path
        entry(105, path: nil),                                                                 // path unreadable
        entry(106, age: 300),                                                                  // under ten minutes
        entry(107, path: home + "/.nvm/versions/node/v22.1.0/lib/zscaler/agent"),              // company security
        entry(108, path: home + "/bin/mytool"),                                                // outside the tool locations
        entry(109, pgid: 600),                                                                 // leader could not be read
        entry(110, pgid: 700),                                                                 // leader alive
        entry(111, uid: 0),                                                                    // another account's
        entry(112, ppid: 4321),                                                                // still has its parent
        entry(113),                                                                            // an app
        entry(114, age: nil),                                                                  // start unreadable
        entry(115, pgid: nil),                                                                 // group unreadable
        entry(700, path: "/bin/zsh", ppid: 1, pgid: 700),
        entry(900, path: "/Applications/Xcode.app/Contents/MacOS/Xcode", pgid: 900),
    ]

    static func inputs(_ entries: [ProcessSnapshot.Entry] = crowd, unreadable: Set<pid_t> = [600], truncated: Bool = false,
                       services: Set<pid_t>? = [103], apps: [pid_t: String?] = [113: nil, 900: "/Applications/Xcode.app"], now: Date = now) -> OrphanProcesses.Inputs {
        let snapshot = ProcessSnapshot(entries: Dictionary(uniqueKeysWithValues: entries.map { ($0.pid, $0) }), unreadable: unreadable, truncated: truncated, taken: now)
        return OrphanProcesses.Inputs(snapshot: snapshot, services: services, apps: apps, home: home, now: now)
    }

    @Test func onlyTheOrphanedToolUnderAToolLocationIsOffered() {
        #expect(OrphanProcesses.candidates(Self.inputs()).map(\.pid) == [100])
        let orphan = OrphanProcesses.candidates(Self.inputs())[0]
        #expect(orphan.name == "node" && orphan.path == Self.node && orphan.footprint == 1_000)
    }

    @Test func aToolInsideXcodesBundleIsOfferedOnlyOnceXcodeHasQuit() {
        let pids = OrphanProcesses.candidates(Self.inputs(apps: [113: nil])).map(\.pid)
        #expect(pids.contains(101) && !pids.contains(900))
    }

    @Test func aPickStaysWithTheSameProcessWhateverItsMemory() {
        let picked = OrphanProcess(pid: 100, start: Self.now, path: Self.node, footprint: 1)
        #expect(picked.isSame(as: OrphanProcess(pid: 100, start: Self.now, path: Self.node, footprint: 900)))
        #expect(!picked.isSame(as: OrphanProcess(pid: 100, start: Self.now.addingTimeInterval(1), path: Self.node, footprint: 1)))
        #expect(!picked.isSame(as: OrphanProcess(pid: 100, start: Self.now, path: Self.home + "/.bun/bin/bun", footprint: 1)))
    }

    @Test func noListOfServicesOrAnIncompleteProcessListOffersNothing() {
        #expect(OrphanProcesses.candidates(Self.inputs(services: nil)).isEmpty)
        #expect(OrphanProcesses.candidates(Self.inputs(truncated: true)).isEmpty)
    }

    @Test func everyToolLocationIsKnownAndNothingElse() {
        let inside = ["/Applications/Xcode-beta.app/Contents/Developer/usr/bin/swift-frontend", "/Library/Developer/CommandLineTools/usr/bin/clang",
                      "/Library/Developer/Toolchains/swift.xctoolchain/usr/bin/swift", "/opt/homebrew/Cellar/node/22/bin/node",
                      "/usr/local/Cellar/python/3.12/bin/python3"]
            + ["Library/Developer/Toolchains/a/b", ".nvm/versions/node/v1/bin/node", ".volta/tools/image/node/bin/node", ".bun/bin/bun",
               ".pyenv/versions/3.12/bin/python", ".local/share/uv/python/bin/python", ".cargo/bin/rust-analyzer",
               ".rustup/toolchains/stable/bin/cargo", ".sdkman/candidates/java/current/bin/java"].map { Self.home + "/" + $0 }
        for path in inside { #expect(OrphanProcesses.isDeveloperTool(path, home: Self.home), "\(path)") }
        for path in ["/usr/bin/python3", "/Applications/Xcode.app/Contents/MacOS/Xcode", "/Applications/Other.app/Contents/Developer/x",
                     Self.home + "/.nvmx/node", Self.home + "/Library/Caches/node", "/opt/homebrew/bin/node"] {
            #expect(!OrphanProcesses.isDeveloperTool(path, home: Self.home), "\(path)")
        }
    }

    @Test func theServiceListIsReadFromItsBlockAndAnythingOddIsNil() {
        let text = "gui/501 = {\n\ttype = login\n\tservices = {\n\t\t    4479   (pe) \tcom.example.one\n\t\t       0      - \tcom.example.two\n\t\t   812      0 \tcom.example.three\n\t}\n\n\tdisabled services = {\n\t\t\"com.example.off\" => disabled\n\t}\n}\n"
        #expect(OrphanProcesses.parseServices(text) == [4479, 812])
        #expect(OrphanProcesses.parseServices("gui/501 = {\n\ttype = login\n}\n") == nil)
        #expect(OrphanProcesses.parseServices("\tservices = {\n\t\tnot-a-pid - label\n\t}\n") == nil)
    }

    @Test func thisMacsServiceListReads() throws {
        let services = try #require(OrphanProcesses.servicePIDs())
        #expect(!services.isEmpty)
    }

    // MARK: Ending one

    final class Signals: @unchecked Sendable {
        private let lock = NSLock()
        private var sent: [Int32] = []
        func add(_ signal: Int32) { lock.withLock { sent.append(signal) } }
        var all: [Int32] { lock.withLock { sent } }
    }

    /// Reads `before` for the check and `after` once a signal was sent; signals are only recorded.
    static func ending(_ before: OrphanProcesses.Inputs?, after: [ProcessSnapshot.Entry]?, signals: Signals, result: Int32 = 0) -> OrphanProcesses.Ending {
        OrphanProcesses.Ending(
            read: { before },
            snapshot: { after.map { ProcessSnapshot(entries: Dictionary(uniqueKeysWithValues: $0.map { ($0.pid, $0) }), taken: now) } },
            signal: { pid, signal in
                #expect(pid == 100)
                signals.add(signal)
                return result
            },
            sleep: { _ in })
    }

    static var orphan: OrphanProcess { OrphanProcesses.candidates(inputs())[0] }

    @Test func itIsAskedToEndOnceWithSIGTERMAndNeverForced() async {
        let signals = Signals()
        #expect(await OrphanProcesses.end(Self.orphan, using: Self.ending(Self.inputs(), after: [], signals: signals)) == .ended)
        #expect(signals.all == [SIGTERM])

        let stubborn = Signals()
        let outcome = await OrphanProcesses.end(Self.orphan, using: Self.ending(Self.inputs(), after: [Self.entry(100)], signals: stubborn))
        #expect(outcome == .stillRunning && outcome.reason == "끝나지 않음" && stubborn.all == [SIGTERM])

        let refused = Signals()
        #expect(await OrphanProcesses.end(Self.orphan, using: Self.ending(Self.inputs(), after: [], signals: refused, result: -1)) == .signalFailed)
    }

    @Test func aProcessThatCannotBeSeenToEndIsNotReportedEnded() async {
        let cut = ProcessSnapshot(entries: [:], truncated: true, taken: Self.now)
        var hidden = ProcessSnapshot(entries: [:], taken: Self.now)
        hidden.hidden = [100]
        let afters = [("listed without a start", ProcessSnapshot(entries: [100: Self.entry(100, age: nil)], taken: Self.now)),
                      ("missing from a cut-short list", cut), ("hidden", hidden)]
        for (name, after) in afters {
            var ending = Self.ending(Self.inputs(), after: [], signals: Signals())
            ending.snapshot = { after }
            #expect(await OrphanProcesses.end(Self.orphan, using: ending) == .stillRunning, "\(name)")
        }
    }

    @Test func aCancelledRunStopsWaitingWithoutASecondSignal() async {
        let signals = Signals()
        var ending = Self.ending(Self.inputs(), after: [Self.entry(100)], signals: signals)
        ending.sleep = { _ in throw CancellationError() }
        #expect(await OrphanProcesses.end(Self.orphan, using: ending) == .stillRunning && signals.all == [SIGTERM])
    }

    @Test func aProcessThatChangedSinceItWasListedIsNotSignalled() async {
        let changes: [(String, OrphanProcesses.Inputs?)] = [
            ("restarted", Self.inputs(Self.crowd.map { $0.pid == 100 ? Self.entry(100, age: 3000) : $0 })),
            ("another binary", Self.inputs(Self.crowd.map { $0.pid == 100 ? Self.entry(100, path: Self.home + "/.bun/bin/bun") : $0 })),
            ("gone", Self.inputs(Self.crowd.filter { $0.pid != 100 })),
            ("now a service", Self.inputs(services: [103, 100])),
            ("leader back", Self.inputs(Self.crowd + [Self.entry(500, path: "/bin/zsh", pgid: 500)])),
            ("unreadable", nil),
        ]
        for (name, now) in changes {
            let signals = Signals()
            let outcome = await OrphanProcesses.end(Self.orphan, using: Self.ending(now, after: [], signals: signals))
            guard case .refused = outcome else { Issue.record("\(name): \(outcome)"); continue }
            #expect(signals.all.isEmpty, "\(name)")
        }
    }
}
