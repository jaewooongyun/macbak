import Foundation

/// Simulator runtimes from `simctl runtime list -j`, and which simulators use each from `simctl list devices -j`. Read
/// the same way when the expanded scan lists them and again right before one is deleted.
enum SimulatorRuntimes {
    struct Runtime: Sendable, Equatable {
        /// One disk image, one build: what `simctl runtime delete` takes and what names the row.
        let identifier: String
        /// The OS the image provides, shared by every build of it, and the key simulators are listed under
        /// ("com.apple.CoreSimulator.SimRuntime.iOS-27-1").
        let runtimeIdentifier: String?
        let build: String?
        let deletable: Bool?
        /// The disk image.
        let path: String?
        let bytes: Int64?
        let lastUsed: Date?
    }

    struct Device: Sendable, Equatable {
        let name: String
        /// nil when the listing did not say.
        let state: String?
    }

    struct Listing: Sendable {
        let runtimes: [Runtime]
        /// Simulators by `runtimeIdentifier`.
        let devices: [String: [Device]]
    }

    /// nil when either listing fails or cannot be read; no developer tools means no runtimes, as for simulators.
    static func read() -> Listing? {
        guard DeveloperTools.available else { return Listing(runtimes: [], devices: [:]) }
        guard let runtimes = readRuntimes(),
              let users = Command.run("/usr/bin/xcrun", ["simctl", "list", "devices", "-j"], timeout: .seconds(30)), users.status == 0,
              let devices = parseDevices(users.stdout) else { return nil }
        return Listing(runtimes: runtimes, devices: devices)
    }

    /// The runtime listing alone, as the wait after a runtime delete reads it; nil when it fails.
    static func readRuntimes() -> [Runtime]? {
        guard DeveloperTools.available else { return [] }
        guard let images = Command.run("/usr/bin/xcrun", ["simctl", "runtime", "list", "-j"], timeout: .seconds(30)), images.status == 0 else { return nil }
        return parseRuntimes(images.stdout)
    }

    /// nil when the listing is not an object of runtimes, each with its identifier.
    static func parseRuntimes(_ data: Data) -> [Runtime]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let dates = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var runtimes: [Runtime] = []
        for value in json.values {
            guard let entry = value as? [String: Any], let identifier = entry["identifier"] as? String else { return nil }
            let used = (entry["lastUsedAt"] as? String).flatMap { dates.date(from: $0) ?? fractional.date(from: $0) }
            runtimes.append(Runtime(identifier: identifier, runtimeIdentifier: entry["runtimeIdentifier"] as? String,
                                    build: entry["build"] as? String, deletable: entry["deletable"] as? Bool, path: entry["path"] as? String,
                                    bytes: (entry["sizeBytes"] as? NSNumber)?.int64Value, lastUsed: used))
        }
        return runtimes
    }

    /// Every simulator under its runtime key, its state nil when unreadable. Unlike `SimulatorList` nothing is dropped:
    /// a simulator without a data folder still stops working when its runtime goes.
    static func parseDevices(_ data: Data) -> [String: [Device]]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let byRuntime = json["devices"] as? [String: Any] else { return nil }
        return byRuntime.mapValues { list in
            // A key that is not a list hides who uses it: one unreadable simulator stands for them.
            guard let list = list as? [Any] else { return [Device(name: "알 수 없는 시뮬레이터", state: nil)] }
            return list.map { item in
                let device = item as? [String: Any]
                return Device(name: device?["name"] as? String ?? device?["udid"] as? String ?? "알 수 없는 시뮬레이터",
                              state: device?["state"] as? String)
            }
        }
    }

    /// Why the runtime may not be deleted now, or nil. The scan shows it as the row's protection; the executor asks again
    /// with a fresh listing right before `simctl runtime delete`.
    /// - Important: Every build of an OS shares its simulators, so one running simulator protects all of them.
    static func refusal(_ identifier: String, in listing: Listing?) -> String? {
        // Passed to `simctl` as is: only a real identifier, never an option or a word such as "all".
        guard UUID(uuidString: identifier) != nil else { return "런타임 식별자를 알아볼 수 없습니다" }
        guard let listing else { return "런타임·시뮬레이터 목록을 읽지 못했습니다" }
        guard let runtime = listing.runtimes.first(where: { $0.identifier == identifier }) else { return "런타임이 목록에 없습니다" }
        guard let key = runtime.runtimeIdentifier, let deletable = runtime.deletable, runtime.path != nil else {
            return "런타임 정보를 다 읽지 못했습니다"
        }
        guard deletable else { return "simctl이 지울 수 없다고 표시한 런타임입니다" }
        let users = listing.devices[key] ?? []
        if users.contains(where: { $0.state == nil }) { return "이 런타임을 쓰는 시뮬레이터의 상태를 읽지 못했습니다" }
        if users.contains(where: { $0.state != "Shutdown" }) { return "이 런타임을 쓰는 시뮬레이터가 켜져 있습니다" }
        return nil
    }
}

/// One row per runtime build, for the expanded scan only: listing them runs `simctl` twice.
/// - Important: Never ticked and never shallow (`manualOnly`): a runtime is shared system-wide and takes a large download
///   to get back, and its simulators stop working until then.
enum RuntimeScanner {
    static func scan(_ context: ScanContext) -> [CleanupCandidate] {
        guard let listing = SimulatorRuntimes.read() else { return [] }
        return rows(listing, context)
    }

    static func rows(_ listing: SimulatorRuntimes.Listing, _ context: ScanContext) -> [CleanupCandidate] {
        listing.runtimes.map { runtime in
            var evidence = Evidence(verified: true, inUse: false, regenerable: true)
            evidence.protectedReason = SimulatorRuntimes.refusal(runtime.identifier, in: listing)
            evidence.downloadCost = true
            evidence.costReason = "다시 쓰려면 Xcode에서 런타임을 내려받아야 합니다."
            let users = runtime.runtimeIdentifier.flatMap { listing.devices[$0] } ?? []
            let usage = users.isEmpty ? "쓰는 시뮬레이터 없음"
                : "이 런타임을 쓰는 시뮬레이터 \(users.count)대가 못 쓰게 될 수 있습니다: " + users.map(\.name).joined(separator: ", ")
            let image = URL(fileURLWithPath: runtime.path ?? "/nonexistent")
            var row = CleanupCandidate(
                id: "runtime." + runtime.identifier,
                name: "\(runtime.runtimeIdentifier.map(SimulatorList.runtimeName) ?? "알 수 없는") 시뮬레이터 런타임 (\(runtime.build ?? "빌드 모름"))",
                detail: (runtime.bytes == nil ? "크기 미확인 · " : "") + usage + " · " + ScanSupport.ago(runtime.lastUsed, now: context.now),
                symbol: "externaldrive", bytes: runtime.bytes ?? 0, evidence: evidence,
                targets: [CleanupTarget(path: image, root: image.deletingLastPathComponent(), identity: nil,
                                        action: .deleteRuntime(identifier: runtime.identifier))],
                lastUsed: runtime.lastUsed)
            row.manualOnly = true
            return row
        }
    }
}
