import Foundation

enum CleanupStatus: CaseIterable, Sendable {
    case ready, review, protected, deferred
}

/// What a scanner found out about one candidate.
/// - Important: `nil` means "not checked" and always resolves to `.protected`.
struct Evidence: Sendable {
    var verified: Bool?
    var inUse: Bool?
    var regenerable: Bool?
    var pinned = false
    var irreplaceable = false
    var userData = false
    var downloadCost = false
    var frequentlyRecreated = false
    /// Changed within the last three days.
    var recentlyUsed = false
    /// Safe to delete, but rebuilding it takes a long time (shared compiler caches, device symbols).
    var slowToRebuild = false
    /// Why the cache rules keep it (the person's data, secrets, settings, security software). Set, it always protects.
    /// - Important: A rule's "keep" goes here, never to `userData`, which only asks for a choice.
    var protectedReason: String?
    /// What a download-cost row costs, in the rule's words ("다음 빌드에서 의존성을 모두 다시 받거나 변환합니다").
    var costReason: String?
    /// Held until the on-device model has looked, so its veto can come before anything is deleted.
    var awaitingModel = false
}

struct Verdict: Equatable, Sendable {
    let status: CleanupStatus
    let reason: String
}

/// Strictest rule first, so `.ready` is reached only when every check passed explicitly.
func evaluate(_ e: Evidence) -> Verdict {
    if e.pinned { return Verdict(status: .protected, reason: "항상 보관하도록 지정했습니다.") }
    if e.irreplaceable { return Verdict(status: .protected, reason: "원본이나 다시 만들 수 없는 데이터가 있습니다.") }
    if let reason = e.protectedReason { return Verdict(status: .protected, reason: reason) }
    if e.awaitingModel { return Verdict(status: .protected, reason: "기기 AI가 확인하는 중입니다.") }
    if e.inUse == true { return Verdict(status: .protected, reason: "진행 중인 작업이 사용하고 있습니다.") }
    if e.recentlyUsed { return Verdict(status: .protected, reason: "최근에 썼습니다.") }
    guard e.verified == true, e.inUse == false else {
        return Verdict(status: .protected, reason: "지워도 되는지 확인할 근거가 부족합니다.")
    }
    if e.frequentlyRecreated { return Verdict(status: .deferred, reason: "자주 쓰여서 정리해도 금방 다시 생깁니다.") }
    if e.userData { return Verdict(status: .review, reason: "안에 든 데이터가 함께 사라집니다.") }
    if e.downloadCost { return Verdict(status: .review, reason: e.costReason ?? "다시 쓰려면 내려받아야 합니다.") }
    if e.slowToRebuild { return Verdict(status: .review, reason: "다시 만드는 데 오래 걸립니다.") }
    guard e.regenerable == true else {
        return Verdict(status: .protected, reason: "다시 만들 수 있는지 확인되지 않았습니다.")
    }
    return Verdict(status: .ready, reason: "다시 만들 수 있고, 쓰는 작업이 없습니다.")
}

struct CleanupCandidate: Identifiable, Sendable {
    let id: String
    let name: String
    let detail: String
    let symbol: String
    let bytes: Int64
    let evidence: Evidence
    /// The size scan hit its time budget, so `bytes` is at least this much.
    var lowerBound = false
    /// What deleting it removes; empty for rows shown for information only.
    var targets: [CleanupTarget] = []
    /// When anything in it last changed; rows sort oldest first, never by size.
    var lastUsed: Date?
    /// Owners checked again just before deleting.
    var guards = CleanupGuards()
    /// When the scan that produced it started; the executor refuses a row without one or older than `resultLifetime`.
    var scannedAt: Date?
    /// What the on-device model saw, when the model rather than the rules offered it. Such rows are never ticked.
    var aiEvidence: String?
    /// The tool's own clean-up command, shown instead of deleting files where the tool asks for it (`uv cache prune`).
    var toolCommand: String?
    /// What the on-device model gets to look at, for rows the rules could not tell inside the cache areas.
    var exploreInput: ExploreInput?
    /// A source vouches that it comes back by itself: the fixed Xcode and log rules, the AI tool catalog, a
    /// developer-table cache the tool rebuilds locally, or an app's Caches folder (Apple's promise and the person's
    /// 3-day rule). Ready rows with it make the shallow clean-up: the menu bar's button and the scheduled loop.
    /// - Important: Set by the scanner that makes the row, never by the on-device model.
    var trusted = false
    /// Deleted only when a person ticks it in the dashboard: never ticked to begin with, never in the shallow clean-up,
    /// whatever its verdict. Rows proven by a method the usual scan does not use carry it, and so do most rows the
    /// expanded scan finds; a build cache it finds outside the usual places that passes without re-proving does not.
    var manualOnly = false
    /// Proven only by borrowing package objects from inside its own build cache (the expanded scan); the usual scan
    /// keeps such a row for the alarm it cannot clear.
    var reproved = false
    /// The clean-up ages the scan judged it by. The executor refuses it once Settings hold other ages.
    var ages = CleanupAges()

    var verdict: Verdict { evaluate(evidence) }

    /// The same row with other evidence, as when the on-device model has looked at it.
    func with(evidence: Evidence, aiEvidence: String?) -> CleanupCandidate {
        var row = CleanupCandidate(id: id, name: name, detail: detail, symbol: symbol, bytes: bytes, evidence: evidence,
                                   lowerBound: lowerBound, targets: targets, lastUsed: lastUsed, guards: guards, scannedAt: scannedAt)
        row.aiEvidence = aiEvidence
        row.toolCommand = toolCommand
        row.exploreInput = exploreInput
        row.trusted = trusted
        row.manualOnly = manualOnly
        row.reproved = reproved
        row.ages = ages
        return row
    }
}

/// An item's place and names, as the cache rules read them, kept for the on-device model.
struct ExploreInput: Sendable, Hashable {
    /// What the model's answer may do to the row.
    enum Role: Sendable, Hashable {
        /// A row the rules could not tell, kept until the model calls it re-creatable; then it becomes a choice.
        case offer
        /// An app cache the person's 3-day rule ticks; the model may only object, which protects it.
        case veto
    }

    let url: URL
    let relative: String
    let inside: String
    let beside: String
    var role = Role.offer
}

extension CleanupCandidate {
    /// Sample rows only — nothing here is read from or applied to the disk. Targets point nowhere real; a scanned row always
    /// has one, and the disk summary counts only rows with something to delete.
    static let samples: [CleanupCandidate] = {
        let checked = Evidence(verified: true, inUse: false, regenerable: true)
        let nowhere = [CleanupTarget(path: URL(fileURLWithPath: "/nonexistent/sample/b"), root: URL(fileURLWithPath: "/nonexistent/sample"), identity: nil, action: .removeItem)]
        func gb(_ value: Double) -> Int64 { Int64(value * 1_000_000_000) }
        func with(_ change: (inout Evidence) -> Void) -> Evidence {
            var e = checked
            change(&e)
            return e
        }
        return [
            CleanupCandidate(id: "xcode-old", name: "끝난 프로젝트의 빌드 캐시", detail: "Xcode · 원본 프로젝트가 사라진 빌드 결과 6개", symbol: "hammer", bytes: gb(28.4), evidence: checked),
            CleanupCandidate(id: "web-cache", name: "오래된 웹 리소스 캐시", detail: "브라우저 · 30일 넘게 쓰지 않은 이미지와 리소스", symbol: "globe", bytes: gb(1.8), evidence: checked),
            CleanupCandidate(id: "ai-tmp", name: "끝난 AI 작업의 임시 빌드", detail: "AI 도구 · 완료 표시가 있는 작업의 생성물", symbol: "sparkles", bytes: gb(1.2), evidence: checked),
            CleanupCandidate(id: "logs", name: "보존 기간이 지난 앱 로그", detail: "앱 3개 · 30일보다 오래된 진단 기록", symbol: "doc.text", bytes: gb(0.6), evidence: checked),
            CleanupCandidate(id: "sim-old", name: "쓰지 않는 시뮬레이터 19대", detail: "Simulator · 모두 종료 상태", symbol: "iphone", bytes: gb(20.7), evidence: with { $0.userData = true }),
            CleanupCandidate(id: "docker", name: "연결되지 않은 컨테이너 이미지", detail: "Docker · 지금 쓰는 컨테이너가 참조하지 않음", symbol: "shippingbox", bytes: gb(12.8), evidence: with { $0.downloadCost = true }),
            CleanupCandidate(id: "node", name: "패키지 다운로드 캐시", detail: "Node.js · 30일 넘게 쓰지 않은 패키지", symbol: "cube", bytes: gb(3.6), evidence: with { $0.downloadCost = true }),
            CleanupCandidate(id: "uv", name: "Serena가 쓰는 Python 환경", detail: "uv · 실행 중인 환경과 연결됨", symbol: "terminal", bytes: gb(27.6), evidence: with { $0.inUse = true }),
            CleanupCandidate(id: "xcode-active", name: "지금 프로젝트의 빌드 캐시", detail: "Xcode · 진행 중인 빌드가 사용", symbol: "hammer.fill", bytes: gb(19.8), evidence: with { $0.inUse = true }),
            CleanupCandidate(id: "system", name: "용도를 확인하지 못한 시스템 데이터", detail: "macOS · 지원하는 규칙이 없음", symbol: "questionmark.folder", bytes: gb(53.2), evidence: with { $0.verified = nil }),
            CleanupCandidate(id: "browser-hot", name: "매일 쓰는 브라우저 캐시", detail: "Chrome · 사용 빈도가 높음", symbol: "arrow.clockwise", bytes: gb(2.4), evidence: with { $0.frequentlyRecreated = true }),
        ].map { sample in
            var sample = sample
            sample.targets = nowhere
            return sample
        }
    }()

    /// Sample rows of the general area, for snapshots: a ready cache, choices from the rules and from the on-device model,
    /// a tool command, and enough protected rows for the group to fold. Targets point nowhere real.
    static let generalSamples: [CleanupCandidate] = {
        let checked = Evidence(verified: true, inUse: false, regenerable: true)
        let nowhere = [CleanupTarget(path: URL(fileURLWithPath: "/nonexistent/sample/a"), root: URL(fileURLWithPath: "/nonexistent/sample"), identity: nil, action: .removeItem)]
        func gb(_ value: Double) -> Int64 { Int64(value * 1_000_000_000) }
        func row(_ id: String, _ name: String, _ detail: String, _ symbol: String, _ size: Double, _ change: (inout Evidence) -> Void = { _ in },
                 ai: String? = nil, command: String? = nil, trusted: Bool = false) -> CleanupCandidate {
            var evidence = checked
            change(&evidence)
            var candidate = CleanupCandidate(id: "general.sample." + id, name: name, detail: detail, symbol: symbol, bytes: gb(size),
                                             evidence: evidence, targets: nowhere)
            candidate.aiEvidence = ai
            candidate.toolCommand = command
            candidate.trusted = trusted
            return candidate
        }
        let keep: (String) -> (inout Evidence) -> Void = { reason in { $0.protectedReason = reason } }
        let cost: (String) -> (inout Evidence) -> Void = { reason in { $0.downloadCost = true; $0.costReason = reason } }
        return [
            row("gradle-build", "build-cache-1", "~/.gradle/caches/build-cache-1 · 12일 전 사용", "hammer", 2.1, trusted: true),
            row("chat-cache", "Cache", "~/Library/Application Support/Chat/Cache · 30일 전 사용", "folder", 0.4),
            row("gradle-modules", "modules-2", "~/.gradle/caches/modules-2 · 9일 전 사용", "hammer", 4.2,
                cost("다음 빌드에서 의존성을 모두 다시 받거나 변환합니다.")),
            row("pip", "pip", "~/Library/Caches/pip · 6일 전 사용", "archivebox", 0.3, cost("패키지를 다시 받습니다."), command: "pip cache purge"),
            row("runtimes", "codex-runtimes", "~/.cache/codex-runtimes · 7일 전 사용", "archivebox", 1.7,
                cost("기기 AI가 다시 만들어지는 캐시로 봤습니다. 내용을 확인하고 고르세요."),
                ai: "18,366 files; program and source code; no hash-like names; oldest 1,037 days ago"),
            row("pending", "moss-models", "~/.cache/moss-models · 43일 전 사용", "sparkle.magnifyingglass", 0.09, keep("기기 AI가 확인하기 전까지 지우지 않습니다.")),
            row("properties", "gradle.properties", "~/.gradle/gradle.properties", "doc", 0.000002, keep("Gradle 설정·스크립트, 비밀 값이 있을 수 있음.")),
            row("node-modules", "node_modules", "~/dev/shop/node_modules", "folder", 0.6, keep("설치한 의존성. 직접 고친 내용과 오프라인 설치가 사라집니다.")),
            row("token", "token", "~/.cache/huggingface/token", "key", 0.000001, keep("키·토큰·암호를 뜻하는 이름이 있습니다.")),
            row("local-storage", "Local Storage", "~/Library/Application Support/Chat/Local Storage", "folder", 0.02, keep("앱 데이터베이스가 있습니다.")),
            row("vm", "vm_bundles", "~/Library/Application Support/AppX/vm_bundles", "shippingbox", 11.3, keep("디스크 이미지나 가상 머신이 있습니다.")),
            row("vpn", "Zscaler", "~/Library/Logs/Zscaler", "lock.shield", 0.01, keep("보안·관리 소프트웨어입니다.")),
            row("unknown", ".npmrc", "~/.npmrc", "doc", 0.000001, keep("무엇인지 판단할 근거가 부족해 지우지 않습니다.")),
        ]
    }()
}
