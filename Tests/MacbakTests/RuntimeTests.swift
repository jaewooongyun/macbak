import Foundation
import Testing
@testable import Macbak

/// Simulator runtimes, from listings shaped like `simctl runtime list -j` and `simctl list devices -j`. Nothing here runs
/// `simctl` or deletes a runtime: the executor's `runtimes` and `deleteRuntime` are replaced.
@Suite struct RuntimeTests {
    static let ios271 = "com.apple.CoreSimulator.SimRuntime.iOS-27-1"
    static let tvos = "com.apple.CoreSimulator.SimRuntime.tvOS-26-4"
    static let a = "5A21A41C-0000-4000-8000-000000000001", b = "48DDD739-0000-4000-8000-000000000002"
    static let c = "1C6F2D9C-0000-4000-8000-000000000003"

    static func runtimesJSON(_ entries: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: Dictionary(uniqueKeysWithValues: entries.map { ($0["identifier"] as? String ?? UUID().uuidString, $0) }))
    }

    static func runtime(_ identifier: String, _ key: String, build: String, size: Int64? = 7_874_743_137, deletable: Bool = true) -> [String: Any] {
        var entry: [String: Any] = ["identifier": identifier, "runtimeIdentifier": key, "build": build, "deletable": deletable,
                                    "path": "/System/Library/AssetsV2/sim/\(build)", "lastUsedAt": "2026-07-15T12:34:00Z", "state": "Ready"]
        if let size { entry["sizeBytes"] = size }
        return entry
    }

    static func devicesJSON(_ byRuntime: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["devices": byRuntime])
    }

    /// Two builds of iOS 27.1 and one tvOS; the iOS simulators are shut down unless a state is given.
    static func listing(iosStates: [String?] = ["Shutdown", "Shutdown"], tvSize: Int64? = 3_725_206_134) throws -> SimulatorRuntimes.Listing {
        let runtimes = try #require(SimulatorRuntimes.parseRuntimes(runtimesJSON([
            runtime(a, ios271, build: "24A94425"), runtime(b, ios271, build: "24A94401"), runtime(c, tvos, build: "23L243a", size: tvSize),
        ])))
        let ios: [[String: Any]] = iosStates.enumerated().map { index, state in
            var device: [String: Any] = ["name": "iPhone \(index + 1)", "udid": "U\(index)"]
            if let state { device["state"] = state }
            return device
        }
        let devices = try #require(SimulatorRuntimes.parseDevices(devicesJSON([ios271: ios, tvos: [] as [Any]])))
        return SimulatorRuntimes.Listing(runtimes: runtimes, devices: devices)
    }

    static func context() -> ScanContext {
        ScanContext(home: URL(fileURLWithPath: "/nonexistent"), now: .now, openFiles: OpenFiles.parse(lsofOutput([])),
                    runningBundleIDs: [], installedBundleIDs: [])
    }

    static func rows(_ listing: SimulatorRuntimes.Listing) -> [String: CleanupCandidate] {
        Dictionary(uniqueKeysWithValues: RuntimeScanner.rows(listing, context()).map { ($0.id, $0) })
    }

    // MARK: Listing and rows

    @Test func theImageAndItsOSAreKeptApart() throws {
        let listing = try Self.listing()
        let ios = listing.runtimes.filter { $0.runtimeIdentifier == Self.ios271 }
        #expect(Set(ios.map(\.identifier)) == [Self.a, Self.b])
        #expect(Set(Self.rows(listing).keys) == ["runtime." + Self.a, "runtime." + Self.b, "runtime." + Self.c])
        #expect(Self.rows(listing)["runtime." + Self.a]?.targets.map(\.action) == [.deleteRuntime(identifier: Self.a)])
    }

    @Test func oneRunningSimulatorProtectsEveryBuildOfItsOS() throws {
        let rows = Self.rows(try Self.listing(iosStates: ["Shutdown", "Booted"]))
        for id in [Self.a, Self.b] {
            #expect(rows["runtime." + id]?.verdict == Verdict(status: .protected, reason: "이 런타임을 쓰는 시뮬레이터가 켜져 있습니다"))
        }
        #expect(rows["runtime." + Self.c]?.verdict.status == .review)
    }

    @Test func aRuntimeWithoutASizeSaysSo() throws {
        let row = try #require(Self.rows(try Self.listing(tvSize: nil))["runtime." + Self.c])
        #expect(row.bytes == 0 && row.detail.hasPrefix("크기 미확인"))
        #expect(!(try #require(Self.rows(try Self.listing())["runtime." + Self.c])).detail.contains("크기 미확인"))
    }

    @Test func theRowNamesTheSimulatorsItWouldBreak() throws {
        let rows = Self.rows(try Self.listing())
        #expect(rows["runtime." + Self.a]?.detail.contains("시뮬레이터 2대가 못 쓰게 될 수 있습니다: iPhone 1, iPhone 2") == true)
        #expect(rows["runtime." + Self.c]?.detail.contains("쓰는 시뮬레이터 없음") == true)
    }

    @Test func aRuntimeRowIsNeverTickedNorShallow() throws {
        for row in RuntimeScanner.rows(try Self.listing(), Self.context()) {
            #expect(row.manualOnly && !row.isPreselected && !row.isShallow && row.isSelectable)
        }
    }

    @Test func malformedListingsAreRefused() {
        #expect(SimulatorRuntimes.parseRuntimes(Data("[]".utf8)) == nil)
        #expect(SimulatorRuntimes.parseRuntimes(Data("{\"x\": {\"build\": \"1\"}}".utf8)) == nil)
        #expect(SimulatorRuntimes.parseDevices(Data("{}".utf8)) == nil)
        // A device without a state is kept, its state unknown; dropping it would hide a user of the runtime.
        let devices = SimulatorRuntimes.parseDevices(Self.devicesJSON([Self.ios271: [["name": "x"]]]))
        #expect(devices?[Self.ios271] == [SimulatorRuntimes.Device(name: "x", state: nil)])
    }

    // MARK: The executor

    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var deleted: [String] = []
        func record(_ id: String) { lock.withLock { deleted.append(id) } }
        var all: [String] { lock.withLock { deleted } }
    }

    static func run(_ listing: SimulatorRuntimes.Listing?, row: CleanupCandidate? = nil, deletes: Bool = true, shallow: Bool = false) async throws
        -> (outcome: CleanupExecutor.Outcome, deleted: [String]) {
        let box = try Sandbox()
        defer { box.remove() }
        let calls = Calls()
        var scanned = try #require(row ?? RuntimeScanner.rows(try Self.listing(), context()).first { $0.id == "runtime." + Self.a })
        scanned.scannedAt = .now
        let target = scanned
        let executor = fixtureExecutor(roots: [], audit: box.root.appending(path: "audit.jsonl")) {
            $0.runtimes = { listing }
            $0.deleteRuntime = { calls.record($0); return deletes }
        }
        let report = await executor.run([target], latest: { _ in target }, shallow: shallow) { _ in }
        return (report.items[0].outcome, calls.all)
    }

    @Test func everyDoubtJustBeforeTheDeleteRefusesIt() async throws {
        let full = try Self.listing()
        let missingField = SimulatorRuntimes.Listing(runtimes: full.runtimes.map {
            $0.identifier == Self.a ? .init(identifier: $0.identifier, runtimeIdentifier: $0.runtimeIdentifier, build: $0.build, deletable: nil,
                                            path: $0.path, bytes: $0.bytes, lastUsed: $0.lastUsed) : $0
        }, devices: full.devices)
        let gone = SimulatorRuntimes.Listing(runtimes: full.runtimes.filter { $0.identifier != Self.a }, devices: full.devices)
        let fixed = SimulatorRuntimes.Listing(runtimes: full.runtimes.map {
            $0.identifier == Self.a ? .init(identifier: $0.identifier, runtimeIdentifier: $0.runtimeIdentifier, build: $0.build, deletable: false,
                                            path: $0.path, bytes: $0.bytes, lastUsed: $0.lastUsed) : $0
        }, devices: full.devices)
        let cases: [(SimulatorRuntimes.Listing?, String)] = [
            (nil, "런타임·시뮬레이터 목록을 읽지 못했습니다"),
            (missingField, "런타임 정보를 다 읽지 못했습니다"),
            (gone, "런타임이 목록에 없습니다"),
            (fixed, "simctl이 지울 수 없다고 표시한 런타임입니다"),
            (try Self.listing(iosStates: ["Shutdown", "Booting"]), "이 런타임을 쓰는 시뮬레이터가 켜져 있습니다"),
            (try Self.listing(iosStates: ["Shutdown", nil]), "이 런타임을 쓰는 시뮬레이터의 상태를 읽지 못했습니다"),
        ]
        for (listing, reason) in cases {
            let result = try await Self.run(listing)
            #expect(result.outcome == .skipped(reason))
            #expect(result.deleted.isEmpty)
        }
    }

    @Test func anIdentifierThatIsNotOneIsNeverPassedOn() async throws {
        var row = try #require(RuntimeScanner.rows(try Self.listing(), Self.context()).first)
        row = CleanupCandidate(id: "runtime.all", name: "x", detail: "", symbol: "x", bytes: 1, evidence: row.evidence,
                               targets: [CleanupTarget(path: URL(fileURLWithPath: "/nonexistent/x"), root: URL(fileURLWithPath: "/nonexistent"),
                                                       identity: nil, action: .deleteRuntime(identifier: "all"))])
        row.manualOnly = true
        let result = try await Self.run(try Self.listing(), row: row)
        #expect(result.outcome == .skipped("런타임 식별자를 알아볼 수 없습니다") && result.deleted.isEmpty)
    }

    @Test func onlyAllClearDeletesOnceAndAFailedCommandIsAFailure() async throws {
        let ok = try await Self.run(try Self.listing())
        #expect(ok.outcome == .deleted && ok.deleted == [Self.a])
        let failed = try await Self.run(try Self.listing(), deletes: false)
        #expect(failed.outcome == .failed("simctl runtime delete 실패") && failed.deleted == [Self.a])
    }

    @Test func aRunNobodyChoseNeverDeletesARuntime() async throws {
        let result = try await Self.run(try Self.listing(), shallow: true)
        #expect(result.outcome.reason != nil && result.deleted.isEmpty)
    }

    // MARK: Where it is read

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var areas: [CleanupCoordinator.Area] = []
        func add(_ area: CleanupCoordinator.Area) { lock.withLock { areas.append(area) } }
        func count(_ area: CleanupCoordinator.Area) -> Int { lock.withLock { areas.filter { $0 == area }.count } }
    }

    @MainActor @Test func onlyTheExpandedScanListsRuntimes() async throws {
        let counter = Counter()
        let listing = try Self.listing()
        var scanning = CleanupCoordinator.Scanning()
        scanning.area = { area, context in
            counter.add(area)
            return area == .runtimes ? RuntimeScanner.rows(listing, context) : []
        }
        scanning.context = { _ in Self.context() }
        let coordinator = CleanupCoordinator(scanning: scanning)
        await coordinator.scan()
        #expect(counter.count(.runtimes) == 0 && counter.count(.xcode) == 1)
        #expect(coordinator.candidates[.runtimes] == nil)

        await coordinator.scanProjects()
        #expect(counter.count(.runtimes) == 1 && counter.count(.xcode) == 1)
        let rows = coordinator.candidates[.runtimes] ?? []
        #expect(rows.count == 3 && rows.allSatisfy { $0.manualOnly && $0.scannedAt != nil })
        #expect(coordinator.all.filter { $0.id.hasPrefix("runtime.") }.count == 3)
    }
}
