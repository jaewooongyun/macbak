import Combine
import Foundation
import Sparkle

/// Whether this copy of the app may check for and install updates, and why not when it may not.
enum UpdaterAvailability: Equatable {
    case on
    case off(String)

    /// - Parameters:
    ///   - bundlePath: the running bundle's path.
    ///   - info: its Info.plist; `scripts/build-app.sh` adds the feed and key only to builds signed with the fixed identity.
    ///   - readOnlyVolume: whether the bundle sits on a read-only volume, such as an opened disk image. Sparkle cannot
    ///     replace an app there, nor one macOS moved to a random folder (App Translocation), and it says nothing then.
    static func decide(bundlePath: String, info: [String: Any], readOnlyVolume: Bool) -> UpdaterAvailability {
        guard bundlePath.hasSuffix(".app") else { return .off("개발 실행이라 업데이트를 확인하지 않습니다.") }
        let configured = ["SUFeedURL", "SUPublicEDKey"].allSatisfy { (info[$0] as? String)?.isEmpty == false }
        guard configured else { return .off("직접 빌드한 앱이라 업데이트를 확인하지 않습니다.") }
        if bundlePath.contains("/AppTranslocation/") || readOnlyVolume {
            return .off("Applications 폴더로 옮긴 뒤 다시 열면 업데이트할 수 있습니다.")
        }
        return .on
    }

    static func current(_ bundle: Bundle) -> UpdaterAvailability {
        let readOnly = (try? bundle.bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        return decide(bundlePath: bundle.bundlePath, info: bundle.infoDictionary ?? [:], readOnlyVolume: readOnly)
    }
}

/// The app's one updater: Sparkle's standard controller, which checks once a day and asks before installing, and the
/// settings the screens show.
/// - Important: Sparkle's updater is main-thread only, so the type is main-actor isolated.
/// - Note: The two settings live in Sparkle's own defaults. They are observed, since Sparkle's update alert can turn
///   automatic installs on by itself, and written only by the setters, because writing an unchanged value would pin it
///   over the Info.plist default.
@MainActor
@Observable
final class AppUpdater {
    let version: String
    /// Why this copy does not update itself, or nil when it does.
    let disabledReason: String?
    private(set) var canCheck = false
    private(set) var automaticallyChecks = false
    private(set) var automaticallyInstalls = false
    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private var watches: Set<AnyCancellable> = []

    /// - Parameter makeController: called once, and only when `availability` is `.on`.
    init(availability: UpdaterAvailability, version: String,
         makeController: () -> SPUStandardUpdaterController = {
             SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
         }) {
        self.version = version
        switch availability {
        case .on:
            let controller = makeController()
            self.controller = controller
            disabledReason = nil
            let updater = controller.updater
            watch(updater.publisher(for: \.canCheckForUpdates)) { $0.canCheck = $1 }
            watch(updater.publisher(for: \.automaticallyChecksForUpdates)) { $0.automaticallyChecks = $1 }
            watch(updater.publisher(for: \.automaticallyDownloadsUpdates)) { $0.automaticallyInstalls = $1 }
            readSettings()
        case .off(let reason):
            controller = nil
            disabledReason = reason
        }
    }

    convenience init(bundle: Bundle) {
        self.init(availability: .current(bundle), version: Self.versionText(bundle.infoDictionary))
    }

    /// For snapshots and previews: never creates Sparkle's updater, whatever the bundle says.
    static func disabled(reason: String) -> AppUpdater {
        AppUpdater(availability: .off(reason), version: versionText(Bundle.main.infoDictionary))
    }

    /// `<version> (<build>)`, as `--version` prints it.
    nonisolated static func versionText(_ info: [String: Any]?) -> String {
        "\(info?["CFBundleShortVersionString"] as? String ?? "dev") (\(info?["CFBundleVersion"] as? String ?? "0"))"
    }

    func checkNow() {
        controller?.checkForUpdates(nil)
    }

    func setAutomaticallyChecks(_ on: Bool) {
        controller?.updater.automaticallyChecksForUpdates = on
        readSettings()
    }

    func setAutomaticallyInstalls(_ on: Bool) {
        controller?.updater.automaticallyDownloadsUpdates = on
        readSettings()
    }

    /// Read right away as well as observed, so a toggle shows its new state before the observation's main-queue hop.
    private func readSettings() {
        automaticallyChecks = controller?.updater.automaticallyChecksForUpdates ?? false
        automaticallyInstalls = controller?.updater.automaticallyDownloadsUpdates ?? false
    }

    /// Hops to the main queue explicitly, so the update never relies on which thread Sparkle changed the value on.
    private func watch(_ values: NSObject.KeyValueObservingPublisher<SPUUpdater, Bool>,
                       _ apply: @escaping @MainActor (AppUpdater, Bool) -> Void) {
        values.receive(on: DispatchQueue.main)
            .sink { [weak self] value in MainActor.assumeIsolated { if let self { apply(self, value) } } }
            .store(in: &watches)
    }
}
