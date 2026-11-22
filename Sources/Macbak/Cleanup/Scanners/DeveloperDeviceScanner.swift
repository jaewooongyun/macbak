import Foundation

/// Device support files for each OS version and simulators. Recent ones are a person's choice: device symbols take
/// minutes to copy again, and a simulator's apps, logins and test state go with it. Long-unused device support joins the
/// shallow clean-up (the person's decision, 2026-11-04); a simulator never does, see `simulators(_:_:)`.
enum DeveloperDeviceScanner {
    /// Device symbols changed within this are being used.
    static let recentFor: TimeInterval = 3 * 86_400
    /// Device symbols untouched this long are copied again only if that device comes back: shallow.
    static let supportShallowAfter: TimeInterval = 14 * 86_400
    /// A simulator neither booted nor changed this long starts ticked on the dashboard.
    static let simulatorQuietAfter: TimeInterval = 5 * 86_400

    static func scan(_ context: ScanContext) -> [CleanupCandidate] {
        deviceSupport(context) + simulators(context)
    }

    private static func deviceSupport(_ context: ScanContext) -> [CleanupCandidate] {
        var candidates: [CleanupCandidate] = []
        for platform in ["iOS", "tvOS", "watchOS"] {
            guard let root = ScanSupport.resolved(context.home, "Library/Developer/Xcode/\(platform) DeviceSupport") else { continue }
            for item in ScanSupport.children(of: root) ?? [] where !item.lastPathComponent.hasPrefix(".") {
                // The same deep checks a run nobody chose makes before deleting, so a row shown as shallow is not refused then.
                let facts = TreeWalk.inspect(item, budget: .seconds(60), alarm: CacheRules.isAlarmName, notice: CacheRules.blocksShallow)
                guard facts.bytes >= ScanSupport.minimumBytes || !facts.isComplete else { continue }
                var evidence = Evidence(verified: facts.isComplete && facts.newest != nil ? true : nil,
                                        inUse: ScanSupport.isOpen(context, [item]), regenerable: true)
                if let alarm = facts.alarm { evidence.protectedReason = CacheRules.alarmReason(alarm) }
                let quiet = facts.idle(at: context.now)
                if let quiet, quiet < recentFor { evidence.recentlyUsed = true }
                let shallow = quiet.map { $0 >= supportShallowAfter } ?? false
                if !shallow { evidence.slowToRebuild = true }
                var row = CleanupCandidate(
                    id: "devicesupport." + PathKey.fold(item.path(percentEncoded: false)), name: "\(platform) \(item.lastPathComponent) 기기 지원 파일",
                    detail: "이 버전 기기를 다시 연결하면 새로 복사함 · \(ScanSupport.ago(facts.newest, now: context.now))",
                    symbol: "iphone.gen3", bytes: facts.bytes, evidence: evidence, lowerBound: !facts.isComplete,
                    targets: [ScanSupport.removal(item, root: root)], lastUsed: facts.newest)
                row.trusted = shallow && facts.noticed == nil
                candidates.append(row)
            }
        }
        return candidates
    }

    /// From `simctl list devices -j`; a failed or malformed listing offers no simulator at all.
    private static func simulators(_ context: ScanContext) -> [CleanupCandidate] {
        guard let devices = SimulatorList.read() else { return [] }
        return simulators(devices, context)
    }

    /// One row per simulator. A shut-down one last booted over `simulatorQuietAfter` ago starts ticked on the dashboard
    /// only if its data folder is as quiet: a `simctl clone` can keep using the original's folder while the original is
    /// never booted. A walk that does not finish leaves it a choice.
    /// - Important: Never shallow. A clone keeps its apps and data in the original's folder, and which simulator is whose
    ///   clone cannot be read while they are shut down (`simctl get_app_container` needs a booted device), so a quiet
    ///   original can still hold a quiet clone's data. Deleting one needs a person who saw the list.
    static func simulators(_ devices: [SimulatorList.Device], _ context: ScanContext) -> [CleanupCandidate] {
        let root = URL(fileURLWithPath: context.home.appending(path: "Library/Developer/CoreSimulator/Devices").path(percentEncoded: false))
        let idle = devices.filter { device in
            device.state == "Shutdown" && device.dataBytes >= ScanSupport.minimumBytes
                && (device.lastUsed.map { context.now.timeIntervalSince($0) >= simulatorQuietAfter } ?? false)
        }
        let walks = Dictionary(zip(idle.map(\.udid), TreeWalk.inspectAll(idle.map { URL(fileURLWithPath: $0.dataPath) }, budget: .seconds(60))),
                               uniquingKeysWith: { first, _ in first })
        return devices.compactMap { device in
            guard device.dataBytes >= ScanSupport.minimumBytes else { return nil }
            let data = URL(fileURLWithPath: device.dataPath)
            var evidence = Evidence(verified: true, inUse: device.state == "Shutdown" ? ScanSupport.isOpen(context, [data]) : true, regenerable: true)
            let quiet = walks[device.udid].flatMap { $0.idle(at: context.now) }.map { $0 >= simulatorQuietAfter } ?? false
            // Long unused and unchanged: ticked on the dashboard; otherwise its state is a choice.
            evidence.userData = !quiet
            return CleanupCandidate(
                id: "simulator." + device.udid, name: "\(device.name) 시뮬레이터 (\(device.runtime))",
                detail: "\(device.state == "Shutdown" ? "꺼짐" : "켜져 있음") · 앱·로그인·테스트 상태가 함께 사라짐 · \(ScanSupport.ago(device.lastUsed, now: context.now))",
                symbol: "ipad.and.iphone", bytes: device.dataBytes, evidence: evidence,
                targets: [CleanupTarget(path: data, root: root, identity: FileIdentity.of(device.dataPath), action: .deleteSimulator(udid: device.udid))],
                lastUsed: device.lastUsed)
        }
    }
}

/// The simulators `simctl` knows, read the same way at scan time and again just before a delete.
enum SimulatorList {
    struct Device: Sendable {
        let udid: String
        let name: String
        let runtime: String
        let state: String
        let dataPath: String
        let dataBytes: Int64
        let lastUsed: Date?
    }

    /// No developer tools means no simulators; `xcrun` is not run then, since its stub would offer to install the tools on
    /// every scan.
    static func read() -> [Device]? {
        guard DeveloperTools.available else { return [] }
        guard let output = Command.run("/usr/bin/xcrun", ["simctl", "list", "devices", "-j"], timeout: .seconds(30)), output.status == 0 else { return nil }
        return parse(output.stdout)
    }

    static func parse(_ data: Data) -> [Device]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let byRuntime = json["devices"] as? [String: [[String: Any]]] else { return nil }
        let dates = ISO8601DateFormatter()
        dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plainDates = ISO8601DateFormatter()
        return byRuntime.flatMap { runtime, devices in
            devices.compactMap { device -> Device? in
                guard let udid = device["udid"] as? String, let state = device["state"] as? String,
                      let dataPath = device["dataPath"] as? String, dataPath.hasPrefix("/") else { return nil }
                let used = (device["lastUsedAt"] as? String).flatMap { dates.date(from: $0) ?? plainDates.date(from: $0) }
                return Device(udid: udid, name: device["name"] as? String ?? udid, runtime: runtimeName(runtime), state: state,
                              dataPath: dataPath, dataBytes: (device["dataPathSize"] as? NSNumber)?.int64Value ?? 0, lastUsed: used)
            }
        }
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-26-5" → "iOS 26.5".
    static func runtimeName(_ identifier: String) -> String {
        let last = identifier.split(separator: ".").last.map(String.init) ?? identifier
        let parts = last.split(separator: "-")
        guard let platform = parts.first else { return last }
        return ([String(platform)] + [parts.dropFirst().joined(separator: ".")]).joined(separator: " ")
    }
}
