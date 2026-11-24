import Foundation

/// Sorts any folder in the home folder into one of three tiers by its path and the names inside and beside it, without
/// opening a file. A line-by-line port of the measured Python rules (`classifier-oracle/frozen-v511`: `prep.decide` and
/// `tiers.code_tier`); `CacheRulesTests` checks every row of their recorded output.
/// - Important: `keep` always wins. A keep is never turned into a choice, and only the code can say `precheck`.
///   `model` means the rules do not know; the on-device model may then look, but only inside ``modelAreas``.
/// - Note: Paths are relative to the home folder, as "Library/Caches/pip". Sandbox containers are judged like the same
///   path at home.
enum CacheRules {
    enum Tier: String, Sendable {
        /// Re-created by the app or tool, nothing visible lost: offered and ticked.
        case precheck
        /// Re-creatable, but the person pays (re-download, re-index, lost past reports): offered unticked.
        case offer
        /// The person's data, settings, secrets, protected areas or security software: never offered.
        case keep
        /// The rules cannot tell.
        case model
    }

    /// A row of the developer table: who must not be running, the tool's own clean-up command, and what is lost.
    struct DevRow: Sendable {
        let tier: Tier
        let processes: String
        let command: String
        let cost: String
    }

    struct Verdict: Sendable {
        let tier: Tier
        /// The rule that decided, in the Python's words ("caches folder", "developer table: ...").
        let why: String
        let devRow: DevRow?
    }

    // MARK: - Tiers

    static func tier(path: String, inside: String, beside: String, home: URL? = nil) -> Verdict {
        let (decision, why) = decide(path: path, inside: inside, beside: beside, home: home)
        let hp = homePath(path)
        if decision == .userData { return Verdict(tier: .keep, why: why, devRow: nil) }
        let all = home.flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0.appending(path: hp).path(percentEncoded: false)) }
        let child = containsKeep(hp, inside, children: all?.sorted())
        if !child.isEmpty { return Verdict(tier: .keep, why: "holds protected " + child, devRow: nil) }
        if let row = devRow(hp) { return Verdict(tier: row.tier, why: "developer table: " + row.cost, devRow: row) }
        if decision == .regenerable {
            if offerWhy.contains(why) || offerPath.search(hp) { return Verdict(tier: .offer, why: why, devRow: nil) }
            return Verdict(tier: .precheck, why: why, devRow: nil)
        }
        return Verdict(tier: .model, why: "", devRow: nil)
    }

    /// `tier`, with a person's rules: a rule turns a `model` verdict for exactly its folder into an offer. A keep, an
    /// offer or a check already decided stays, a folder whose tool frees it itself (`reclaim`) is never ruled, and a
    /// rule stops applying once the folder's names show someone's state (`stateNames`), as when sessions appear in it
    /// after the approval.
    static func tier(path: String, inside: String, beside: String, home: URL? = nil, userRules: Set<String>) -> Verdict {
        let verdict = tier(path: path, inside: inside, beside: beside, home: home)
        guard verdict.tier == .model, userRules.contains(path), reclaimTip(path) == nil,
              (home.map { stateName(of: $0.appending(path: path), listing: inside) } ?? stateName(in: inside)) == nil else { return verdict }
        return Verdict(tier: .offer, why: userRuleWhy, devRow: nil)
    }

    /// Names that mean a folder keeps someone's history, settings or work. Seen among its names, a "re-created" finding
    /// proposes no rule and an approved rule stops applying, since a rule hands the whole folder to a tick: measured
    /// 2026-11-24, the model proposed Xcode's coding assistant folder, which holds agent sessions, memories and backups
    /// beside a re-downloadable binary.
    /// - Note: Only ever withholds a choice, so a name too many errs on the safe side.
    static let stateNames: Set<String> = [
        "sessions", "session", "session storage", "memories", "memory", "history", "backups", "backup", "accounts", "profiles",
        "preferences", "settings", "config", "cookies", "local storage", "indexeddb", "databases", "projects", "workspaces",
        "conversations", "chats", "documents", "saves", "settings.json", "config.json", "mcp-servers.json",
    ]

    /// The first name in a rules listing (`a/ (b/, c), d`) that `stateNames` holds, any case, with or without its
    /// extension or a leading dot (`sessions.jsonl`, `.config`).
    static func stateName(in listing: String) -> String? {
        listing.split(whereSeparator: { ",()".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
            .first { name in
                let lower = name.lowercased()
                let stem = (lower as NSString).deletingPathExtension
                return stateNames.contains(lower) || stateNames.contains(stem.hasPrefix(".") ? String(stem.dropFirst()) : stem)
            }
    }

    /// `stateName(in:)` over the rules listing and every name directly inside the folder: the listing stops after eight
    /// names, so a `sessions/` sorted after many hash-named files would not show in it.
    static func stateName(of folder: URL, listing: String) -> String? {
        let children = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        return stateName(in: listing) ?? stateName(in: children.joined(separator: ", "))
    }

    static let userRuleWhy = "user rule"

    /// Why a `keep` or `model` verdict protects the item, in the words shown on its row.
    static func protectedReason(_ verdict: Verdict) -> String {
        if let row = verdict.devRow { return row.cost.isEmpty ? "개발 도구의 설정이나 데이터입니다." : row.cost + "." }
        if verdict.why.hasPrefix("holds protected ") {
            return "지우면 안 되는 \(verdict.why.dropFirst("holds protected ".count))이(가) 안에 있습니다."
        }
        switch verdict.why {
        case "zone": return "사람이 직접 관리하는 위치입니다."
        case "security or management software (keep)": return "보안·관리 소프트웨어입니다."
        case "image": return "디스크 이미지나 가상 머신이 있습니다."
        case "simulator device": return "시뮬레이터 기기 데이터입니다."
        case "user content inside": return "문서·사진·데이터베이스 같은 사용자 데이터가 있습니다."
        case "secret-like name": return "키·토큰·암호를 뜻하는 이름이 있습니다."
        case "settings or user library inside": return "설정이나 직접 만든 자료가 있습니다."
        case "database files inside": return "앱 데이터베이스가 있습니다."
        case "chromium state": return "로그인·북마크 같은 브라우저 상태입니다."
        case "settings file": return "설정 파일입니다."
        case "user-like name in a cache or log area": return "캐시 위치지만 사용자 데이터로 보이는 이름이 있습니다."
        default: return unsureReason
        }
    }

    /// Why a row stays when no rule could tell what it is.
    static let unsureReason = "무엇인지 판단할 근거가 부족해 지우지 않습니다."
    /// Why a row stays when the on-device model could not tell either.
    static let modelUnsureReason = "기기 AI도 지워도 되는지 판단하지 못했습니다."

    /// Kept only because nothing could tell what it is; the disk summary counts these.
    static func isUnsure(_ row: CleanupCandidate) -> Bool {
        row.evidence.protectedReason.map { [unsureReason, modelUnsureReason].contains($0) } ?? false
    }

    /// Where Apple (Caches), the XDG convention (~/.cache) or the folder's purpose (Logs) promise re-creatable contents.
    static let modelAreas = ["Library/Caches/", ".cache/", "Library/Logs/"]

    /// The playground: the model may turn a `model` item into an offer only here, and only for readable items.
    static func modelMayOffer(path: String, inside: String) -> Bool {
        let hp = homePath(path)
        return modelAreas.contains(where: hp.hasPrefix) && !inside.hasPrefix("(unreadable)") && !inside.hasPrefix("(empty)")
    }

    static let offerWhy: Set<String> = ["creative app cache", "app-managed versions", "runtime installs"]
    static let offerPath = Pattern(
        #"/Service Worker/(CacheStorage|ScriptCache)(/|$)"#
        + #"|(^|/)Crashpad(/|$)"#
        + #"|\.ShipIt(/|$)|org\.sparkle-project\.Sparkle"#
        + #"|^Library/Application Support/Steam/steamapps/(downloading|workshop)(/|$)"#
        + #"|^Library/Application Support/minecraft/(assets|versions|libraries|runtime)(/|$)"#
        + #"|^\.cache/huggingface(/|$)"#
        + #"|(^|/)(mini|ana)conda3?/pkgs(/|$)|^\.conda/pkgs(/|$)"#
        + #"|/Media Cache Files(/|$)|/Render Files(/|$)|Previews\.lrdata(/|$)|/Peak Files(/|$)"#)

    /// Developer tool locations. The first matching row wins, so specific rows come before general ones.
    /// Sources: Gradle, Android Studio, npm, pip, uv, pnpm, Yarn and Playwright documentation; the GPT developer-cache
    /// review; the user's reference screen (`dev-cache-table.md`).
    static let devTable: [(Pattern, DevRow)] = devRows.map { (Pattern($0.0), DevRow(tier: $0.1, processes: $0.2, command: $0.3, cost: $0.4)) }

    private static let devRows: [(String, Tier, String, String, String)] = [
        // Android
        (#"^\.gradle/caches/build-cache-\d+(/|$)"#, .precheck, "gradle", "", "첫 빌드가 조금 느려집니다"),
        (#"^\.gradle/caches/(transforms-\d+|jars-\d+|modules-2)(/|$)"#, .offer, "gradle", "", "다음 빌드에서 의존성을 모두 다시 받거나 변환합니다"),
        (#"^\.gradle/caches/\d+(\.\d+)+(/|$)"#, .precheck, "gradle", "", "다음 빌드에서 스크립트를 다시 컴파일합니다"),
        (#"^\.gradle/caches$"#, .offer, "gradle", "", "의존성 캐시가 들어 있어 다음 빌드에서 다시 받습니다"),
        (#"^\.gradle/wrapper/dists(/|$)"#, .offer, "gradle", "", "Gradle 배포판을 다시 받습니다"),
        (#"^\.gradle/jdks(/|$)"#, .offer, "gradle", "", "툴체인 JDK를 다시 받습니다"),
        (#"^\.gradle/daemon/[^/]+/daemon-\d+\.out\.log$"#, .precheck, "gradle", "", "지난 데몬 로그"),
        (#"^\.gradle(/|$)"#, .keep, "", "", "Gradle 설정·스크립트, 비밀 값이 있을 수 있음"),
        (#"^\.kotlin/daemon(/|$)"#, .keep, "", "", ""),
        (#"^Library/Caches/(Google/AndroidStudio|JetBrains/)[^/]+(/|$)"#, .offer, "studio", "File > Invalidate Caches", "다시 인덱싱하고 로컬 히스토리가 사라집니다"),
        (#"^Library/Logs/(Google/AndroidStudio|JetBrains/)[^/]+(/|$)"#, .precheck, "studio", "", "지난 IDE 로그"),
        (#"^Library/Application Support/(Google/AndroidStudio|JetBrains/)"#, .keep, "", "", "IDE 설정과 플러그인"),
        (#"^Library/Android/sdk/(system-images|build-tools|platforms|platform-tools|emulator|ndk|cmake|sources)(/|$)"#, .offer, "studio,emulator", "sdkmanager --uninstall", "SDK 구성요소를 다시 받습니다. 옛 버전은 없을 수 있습니다"),
        (#"^\.android/(avd|adbkey|adbkey\.pub|debug\.keystore)(/|$)"#, .keep, "", "", "에뮬레이터 데이터나 서명 키"),
        (#"^\.android/cache(/|$)"#, .offer, "studio", "", "SDK 다운로드를 다시 합니다"),
        (#"^\.android(/|$)"#, .keep, "", "", ""),
        (#"\.hprof$"#, .offer, "", "", "힙 덤프. 크래시 원인을 찾을 때 필요할 수 있습니다"),
        (#"^\.konan(/|$)"#, .offer, "gradle", "", "Kotlin/Native 의존성을 다시 받습니다"),
        (#"^\.pub-cache/(hosted|git)(/|$)"#, .offer, "dart,flutter", "dart pub cache clean", "Dart 패키지를 다시 받습니다"),
        (#"^\.pub-cache(/|$)"#, .keep, "", "", "전역 Dart 도구와 인증 정보"),
        // Apple platforms
        (#"^Library/Developer/Xcode/DerivedData$"#, .offer, "xcode", "", "모든 프로젝트가 다시 빌드·인덱싱합니다. 프로젝트별로 따로 보입니다"),
        (#"^Library/Developer/Xcode/DeviceLogs(/|$)"#, .offer, "xcode", "", "기기에서 가져온 크래시 기록은 다시 만들 수 없습니다"),
        (#"^Library/Developer/Xcode/DocumentationCache(/|$)"#, .offer, "xcode", "", "오프라인 문서를 다시 받습니다"),
        (#"^Library/Developer/Xcode/DerivedData(/|$)"#, .precheck, "xcode", "Product > Clean Build Folder", "다음 빌드와 인덱싱이 오래 걸립니다"),
        (#"^Library/Developer/Xcode/(iOS|watchOS|tvOS|visionOS) DeviceSupport(/|$)"#, .offer, "xcode", "", "기기를 연결하면 심벌을 다시 복사합니다"),
        (#"^Library/Developer/Xcode/(Archives|UserData|XCPGDevices)(/|$)"#, .keep, "", "", ""),
        (#"^Library/Developer/CoreSimulator/Caches(/|$)"#, .offer, "simulator", "", "시뮬레이터 캐시를 다시 만듭니다"),
        (#"^Library/Developer/CoreSimulator/Devices(/|$)"#, .keep, "", "xcrun simctl delete unavailable", "시뮬레이터 기기에 앱 데이터가 있습니다"),
        (#"^Library/Caches/org\.swift\.swiftpm(/|$)"#, .offer, "xcode,swift", "swift package purge-cache", "패키지를 다시 받습니다"),
        (#"^(\.swiftpm|Library/org\.swift\.swiftpm)(/|$)"#, .keep, "", "", "SwiftPM 보안·설정"),
        (#"^Library/Caches/CocoaPods(/|$)"#, .precheck, "pod", "pod cache clean --all", "Pod을 다시 받습니다"),
        (#"^\.cocoapods/repos(/|$)"#, .offer, "pod", "", "스펙 저장소를 다시 내려받습니다"),
        (#"^\.(mint|fastlane)(/|$)"#, .keep, "", "", ""),
        // Python
        (#"^Library/Caches/pip(/|$)"#, .precheck, "pip", "pip cache purge", "패키지를 다시 받습니다"),
        (#"^Library/Caches/pypoetry/virtualenvs(/|$)"#, .keep, "", "poetry env remove", "Poetry 가상환경"),
        (#"^Library/Caches/pypoetry/(cache|artifacts)(/|$)"#, .precheck, "poetry", "poetry cache clear --all", "패키지를 다시 받습니다"),
        (#"^\.cache/uv(/|$)"#, .offer, "uv", "uv cache prune", "uv 명령으로 정리하세요. uv는 캐시를 직접 지우는 것이 안전하지 않다고 안내합니다"),
        (#"^\.local/share/(uv|pipx)(/|$)"#, .keep, "", "", "설치한 Python과 도구"),
        (#"^Library/Caches/pdm(/|$)"#, .precheck, "pdm", "pdm cache clear", "패키지를 다시 받습니다"),
        (#"^Library/Caches/hatch(/|$)"#, .offer, "hatch", "", "Hatch 버전마다 내용이 다릅니다"),
        (#"(^|/)(mini|ana)conda3?/(envs|conda-meta)(/|$)|^\.conda/envs(/|$)|^\.pyenv(/|$)"#, .keep, "", "", "Python 환경과 인터프리터"),
        (#"^\.cache/torch/hub(/|$)"#, .offer, "python", "", "모델 가중치를 다시 받습니다"),
        (#"^\.cache/huggingface$"#, .keep, "", "", "토큰·설정이 있을 수 있는 HF_HOME 루트. hub·datasets는 따로 보입니다"),
        (#"^\.cache/huggingface/(hub|datasets|xet)(/|$)"#, .offer, "python", "hf cache", "모델과 데이터셋을 다시 받습니다"),
        (#"^(Library/Jupyter|\.keras|nltk_data)(/|$)"#, .keep, "", "", ""),
        // JVM and Go
        (#"^\.m2/repository(/|$)"#, .offer, "java,mvn", "", "산출물을 다시 받습니다. 로컬에서 설치한 것은 다른 곳에 없을 수 있습니다"),
        (#"^\.m2(/|$)"#, .keep, "", "", "Maven 설정과 인증 정보"),
        (#"^Library/Caches/go-build(/|$)"#, .precheck, "go", "go clean -cache", "다음 Go 빌드가 느려집니다"),
        (#"^go/pkg/mod(/|$)"#, .offer, "go", "go clean -modcache", "모듈을 다시 받습니다. 오프라인 빌드가 실패합니다"),
        // Node.js
        (#"^\.npm/(_cacache|_npx|_logs)(/|$)"#, .precheck, "npm,node", "npm cache clean --force", "패키지를 다시 받습니다"),
        (#"^Library/Caches/Yarn(/|$)"#, .precheck, "yarn,node", "yarn cache clean", "패키지를 다시 받습니다"),
        (#"^\.yarn/berry/cache(/|$)"#, .offer, "yarn,node", "yarn cache clean", "Plug'n'Play 프로젝트는 yarn install을 다시 해야 합니다"),
        (#"(^|/)\.yarn/cache(/|$)"#, .keep, "", "", "프로젝트가 커밋한 오프라인 캐시"),
        (#"^Library/pnpm/store(/|$)"#, .offer, "pnpm,node", "pnpm store prune", "패키지를 다시 받습니다"),
        (#"^\.bun/install/cache(/|$)"#, .precheck, "bun", "", "패키지를 다시 받습니다"),
        (#"^Library/Caches/deno(/|$)"#, .precheck, "deno", "", "모듈을 다시 받습니다"),
        (#"^(\.nvm|\.volta|\.local/share/fnm)(/|$)"#, .keep, "", "", "설치한 Node 버전과 전역 패키지"),
        (#"(^|/)node_modules(/|$)"#, .keep, "", "npm install", "설치한 의존성. 직접 고친 내용과 오프라인 설치가 사라집니다"),
        (#"^Library/Caches/node/corepack(/|$)"#, .offer, "node", "corepack cache clean", "고정한 패키지 관리자를 다시 받습니다"),
        (#"^Library/Caches/node-gyp(/|$)"#, .precheck, "node", "", "Node 헤더를 다시 받습니다"),
        (#"^Library/Caches/electron(-builder)?(/|$)"#, .precheck, "node", "", "Electron을 다시 받습니다"),
        (#"^(\.cache/puppeteer|Library/Caches/ms-playwright|Library/Caches/Cypress)(/|$)"#, .offer, "node", "npx playwright install / npx puppeteer browsers install", "테스트 브라우저를 다시 설치해야 합니다"),
        // Creative and game tools (2026-11-24): caches their apps make again or download again.
        (#"^Library/Application Support/Adobe/Common/Media Cache(/|$)"#, .offer, "adobe", "", "Premiere·After Effects가 다시 만듭니다. 프로젝트를 처음 열 때 느려집니다"),
        (#"^Library/Application Support/Epic/UnrealEngine/Common/DerivedDataCache(/|$)"#, .offer, "unreal", "", "셰이더를 다시 컴파일해 프로젝트를 처음 열 때 오래 걸립니다"),
        (#"^Library/Unity/Asset Store-5\.x(/|$)"#, .offer, "unity", "", "Asset Store에서 받은 패키지를 다시 받아야 합니다"),
    ]

    /// How to free the space of a large item the rules keep, the tool's own way. Shown on the row only: never run, and
    /// never a reason to delete anything. A row it matches stays protected, is never shown to the on-device model and
    /// never turned into a choice by a person's rule, since deleting its files by hand would break the tool.
    static let reclaim: [(Pattern, note: String, command: String?)] = [
        (Pattern(#"^Library/Containers/com\.docker\.docker/Data/vms(/|$)"#),
         "Docker의 이미지·컨테이너·볼륨이 모두 든 디스크입니다. 파일을 지우지 말고 Docker에서 쓰지 않는 것을 지우세요.", "docker system prune"),
        (Pattern(#"^\.rustup/toolchains(/|$)"#), "설치한 Rust 툴체인입니다. 쓰지 않는 버전을 명령으로 지우세요.", "rustup toolchain uninstall <이름>"),
        (Pattern(#"^\.android/avd(/|$)"#), "Android 에뮬레이터 기기입니다. Android Studio의 Device Manager에서 쓰지 않는 기기를 지우세요.", nil),
        // LM Studio moves a model it imports into this folder, so a model made on this Mac may have no other copy.
        (Pattern(#"^\.lmstudio/models(/|$)"#), "LM Studio의 모델입니다. 직접 가져온 모델은 다른 곳에 사본이 없을 수 있어, LM Studio의 My Models에서 지우세요.", nil),
    ]

    /// The `reclaim` row for a path relative to the home folder, if any.
    /// - Note: Matched on the path as it is, not folded like a sandbox container's (`homePath`): the tip names where the
    ///   tool really keeps it, as Docker's disk inside its container.
    static func reclaimTip(_ path: String) -> (note: String, command: String?)? {
        reclaim.first { $0.0.search(path) }.map { ($0.note, $0.command) }
    }

    /// Developer-table rows (by pattern) whose contents the tool rebuilds on this Mac without downloading anything.
    /// Kept apart from the table so a new row is never trusted by accident; a test checks every entry is in the table.
    static let localRebuild: Set<String> = [
        #"^\.gradle/caches/build-cache-\d+(/|$)"#,
        #"^\.gradle/caches/\d+(\.\d+)+(/|$)"#,
        #"^Library/Caches/go-build(/|$)"#,
    ]

    /// Whether the developer table vouches that a ready item comes back by itself, locally: a pre-ticked table row the
    /// tool rebuilds without the network. Heuristic rules, download caches and the model's answers never qualify.
    static func rebuildsLocally(_ verdict: Verdict, path: String) -> Bool {
        guard verdict.tier == .precheck, verdict.devRow != nil,
              let row = devTable.first(where: { $0.0.search(homePath(path)) }) else { return false }
        return localRebuild.contains(row.0.regex.pattern)
    }

    /// The cost text a row shows, ending in a full stop, or nil when the table has none.
    static func costReason(_ verdict: Verdict) -> String? {
        if verdict.why == userRuleWhy { return "기기 AI가 앱이 다시 만드는 것으로 보고, 직접 승인한 규칙입니다. 내용을 확인하고 고르세요." }
        guard let cost = verdict.devRow?.cost, !cost.isEmpty else { return nil }
        return cost + "."
    }

    static func devRow(_ hp: String) -> DevRow? {
        devTable.first { $0.0.search(hp) }?.1
    }

    /// A parent that holds a protected child is never offered whole (`Library/Caches/pypoetry` holds `virtualenvs/`).
    /// - Parameter children: every direct child, when the folder could be read. The listing shows only the first eight
    ///   names, and the whole folder's contents are what gets deleted.
    static func containsKeep(_ hp: String, _ inside: String, children: [String]? = nil) -> String {
        guard devRow(hp)?.tier != .keep else { return "" }
        let names = children ?? (inside.hasPrefix("(") ? [] : inside.components(separatedBy: ", ").map {
            trimTrailingSlashes(($0.components(separatedBy: " (").first ?? "").trimmingCharacters(in: .whitespaces))
        })
        return names.first { !$0.isEmpty && devRow(hp + "/" + $0)?.tier == .keep } ?? ""
    }

    /// Names that keep a row wherever they are inside it: keys, password stores, database server files, disk images.
    /// - Important: Narrower than the listing checks on purpose. Package and build caches extract documents, pictures,
    ///   source and JSON by the thousand, so only names that never belong in a cache are looked for deep.
    static let alarmNames: Set<String> = ["id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", "known_hosts", "authorized_keys", "credentials",
                                          ".netrc", ".pgpass", "pg_version", "postgresql.conf", "ibdata1", "mongod.lock",
                                          "dump.rdb", "wiredtiger", "wallet.dat"]
    /// The one alarm name that is a folder: a PostgreSQL data folder's write-ahead log.
    static let alarmFolderNames: Set<String> = ["pg_wal"]
    static let alarmExtensions = [".kdbx", ".keychain", ".keychain-db", ".wallet", ".vmdk", ".qcow2", ".vdi", ".vbox", ".vmwarevm", ".utm", ".pvm",
                                  ".hdd", ".sparsebundle", ".sparseimage", ".xcarchive", ".avd"]

    static let sourceExtensions = [".h", ".hh", ".hpp", ".c", ".cc", ".cpp", ".cxx", ".m", ".mm", ".swift", ".inc"]

    /// - Note: A file name matches only a file: `~/.aws/credentials` is a file, while a network library's sources, which SwiftPM puts
    ///   in the build caches of apps that use it, hold `credentials` folders of C++ code. Such a folder is judged by what
    ///   it holds: anything but source code in it alarms, unless git shows it is a package's own unchanged file
    ///   (a checked-out `CMakeLists.txt`). Extensions match folders too: keychains, disk images and VMs are often bundles.
    @Sendable static func isAlarmName(_ url: URL, isFolder: Bool) -> Bool { isAlarmName(url, isFolder: isFolder, reprove: false) }

    /// The same, with `reprove` and the proof's deadline handed to the package proof (the expanded scan only).
    @Sendable static func isAlarmName(_ url: URL, isFolder: Bool, reprove: Bool, until: ContinuousClock.Instant? = nil) -> Bool {
        let low = url.lastPathComponent.lowercased()
        if alarmExtensions.contains(where: low.hasSuffix) { return true }
        if isFolder { return alarmFolderNames.contains(low) }
        if alarmNames.contains(low) { return true }
        let folder = url.deletingLastPathComponent().path(percentEncoded: false) + "/"
        guard folder.range(of: "/credentials/", options: .caseInsensitive) != nil else { return false }
        return !sourceExtensions.contains(where: low.hasSuffix) && !PackageCheckout.isPristine(url, reprove: reprove, until: until)
    }

    /// Names that, anywhere inside, keep a row out of the shallow clean-up (which runs without a click), though the
    /// row may still be ticked in the dashboard: documents, mail and certificate bundles. Pictures, source and JSON are
    /// left out on purpose; caches hold them by the thousand.
    static let shallowBlockerExtensions = [".pdf", ".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx", ".key", ".numbers", ".pages", ".rtf",
                                           ".epub", ".eml", ".emlx", ".p12", ".pfx"]

    /// - Note: A document SwiftPM checked out with a package (a package's icons, test files or design
    ///   notes) does not hold a row back when git shows it is tracked and unchanged; one changed or added there does.
    @Sendable static func blocksShallow(_ url: URL) -> Bool { blocksShallow(url, reprove: false) }

    /// The same, with `reprove` and the proof's deadline handed to the package proof (the expanded scan only).
    @Sendable static func blocksShallow(_ url: URL, reprove: Bool, until: ContinuousClock.Instant? = nil) -> Bool {
        shallowBlockerExtensions.contains(where: url.lastPathComponent.lowercased().hasSuffix)
            && !PackageCheckout.isPristine(url, reprove: reprove, until: until)
    }

    /// The reason shown on a row kept for a deep alarm name.
    static func alarmReason(_ name: String) -> String {
        "지우면 안 되는 \(name)이(가) 안에 있습니다."
    }

    // MARK: - Rules (prep.decide)

    enum Decision: Sendable { case regenerable, userData, unknown }

    static let zones = ["Documents/", "Desktop/", "Downloads/", "Pictures/", "Movies/", "Music/", "Library/Mail/", "Library/Messages/",
                        "Library/Mobile Documents/", "Library/CloudStorage/", "Library/Keychains", "Library/Calendars",
                        "Library/Application Support/AddressBook", ".ssh", ".gnupg", ".aws", "Library/Developer/Xcode/Archives",
                        "Library/Autosave Information"]
    static let imageExt = [".pvm", ".vmwarevm", ".utm", ".hdd", ".vmdk", ".qcow2", ".raw", ".img", ".sparsebundle", ".sparseimage", ".avd",
                           ".xcarchive", ".vdi", ".vbox"]
    static let userExt = [".pdf", ".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx", ".key", ".numbers", ".pages", ".md", ".jpg", ".jpeg",
                          ".heic", ".mov", ".mp4", ".m4a", ".mp3", ".wav", ".swift", ".ts", ".tsx", ".py", ".kbx", ".kdbx", ".logicx", ".fcpbundle",
                          ".png", ".gif", ".tif", ".tiff", ".bmp", ".psd", ".psb", ".ai", ".sketch", ".fig", ".csv", ".rtf", ".epub", ".sav", ".asd"]
    static let userNames = ["id_rsa", "id_ed25519", "credentials", "known_hosts", "pg_version", "pg_wal", "postgresql.conf", "dump.rdb",
                            "ibdata1", "mongod.lock", "wiredtiger"]
    static let dbExt = [".rdb", ".mdf", ".frm", ".ibd"]
    static let configExt = [".json", ".plist", ".ini", ".conf", ".cfg", ".toml", ".xml", ".tres", ".blend", ".sqlite", ".db"]
    static let profileMark: Set<String> = ["Cookies", "Preferences", "Local State", "IndexedDB", "Local Storage", "GPUCache", "Code Cache",
                                           "History", "Bookmarks", "Login Data"]
    static let chromiumRegen: Set<String> = ["Cache", "Code Cache", "GPUCache", "GPUPersistentCache", "DawnCache", "DawnWebGPUCache",
                                             "DawnGraphiteCache", "GraphiteDawnCache", "GrShaderCache", "ShaderCache", "Shared Dictionary", "Crashpad"]
    static let chromiumUser: Set<String> = ["IndexedDB", "Local Storage", "Session Storage", "WebStorage", "blob_storage", "Cookies",
                                            "Preferences", "Local State", "Bookmarks", "History", "Login Data", "Web Data", "Extension State"]
    static let toolCaches = [".npm/_cacache", ".npm/_npx", ".npm/_logs", ".npm/_prebuilds", ".bun/install/cache", ".gradle/caches",
                             ".cargo/registry/cache", ".m2/repository", "go/pkg/mod/cache", ".pub-cache", ".gem/specs", ".deno/cache",
                             "miniconda3/pkgs", ".terraform.d/plugin-cache", "Library/Developer/Xcode/DerivedData",
                             "Library/Developer/Xcode/iOS DeviceSupport", ".nuget/packages", ".yarn/berry/cache", ".ivy2/cache",
                             ".composer/cache", ".cargo/git", "Library/Developer/CoreSimulator/Caches"]
    static let buildNames = [".next/cache"]
    static let cacheLikeExt: Set<String> = ["", ".log", ".gz", ".ips", ".diag", ".crash", ".tmp", ".bin", ".idx", ".index", ".lock", ".pid",
                                            ".cache", ".wasm", ".shm", ".wal", ".journal", ".etag", ".dat", ".pack"]
    static let logExt: Set<String> = ["", ".log", ".txt", ".gz", ".ips", ".diag", ".crash", ".json", ".ndjson", ".trace", ".spin", ".hang"]
    static let userDirs: Set<String> = ["documents", "photos", "pictures", "videos", "movies", "music", "backups", "backup", "user-backups",
                                        "exports", "export", "saves", "save", "projects", "notes", "attachments", "recordings",
                                        "recovered files", "screenshots", "wallets", "keys", "vault", "drafts"]
    /// Whole words in a name. Extensions say the format; words say the meaning.
    static let secretWords: Set<String> = ["token", "tokens", "secret", "secrets", "password", "passwords", "passwd", "credential",
                                           "credentials", "wallet", "wallets", "seed", "mnemonic", "privkey", "apikey", "auth", "netrc",
                                           "kdbx", "keychain"]
    static let softWords: Set<String> = ["backup", "backups", "bak", "settings", "export", "exports", "draft", "drafts", "autosave",
                                         "autosaved", "recover", "recovered", "recovery", "save", "saves", "savegame", "diary", "notes",
                                         "note", "todo", "bookmark", "bookmarks", "contacts", "history", "untitled", "session",
                                         "sessions", "account", "accounts"]
    /// Pure log or crash formats only: a .gz or .trace may be something the person made.
    static let strongExt: Set<String> = [".log", ".ips", ".crash", ".diag", ".spin", ".hang"]
    /// The first level under these areas names the owner app or tool, not the content.
    static let ownerLevel = Pattern(#"^(?:Library/Caches|Library/Logs|\.cache)/[^/]+$"#)
    /// Security, VPN, device-management and document-protection software: never cleaned, whatever its folder looks like.
    /// Long names match inside a component with spaces and punctuation removed; short ones must be a whole word.
    static let securityLong = ["paloalto", "globalprotect", "pangps", "crowdstrike", "sentinelone", "symantec", "norton", "mcafee", "sophos",
                               "jamf", "kandji", "mosyle", "intune", "companyportal", "zscaler", "netskope", "fortinet", "forticlient",
                               "anyconnect", "ciscosecure", "umbrella", "f5vpn", "f5networks", "f5access", "ahnlab", "avast", "kaspersky",
                               "malwarebytes", "bitdefender", "trendmicro", "carbonblack", "tanium", "cylance", "cortexxdr", "jness",
                               "fasoo", "softcamp", "markany", "somansa", "nprotect", "touchen", "veraport", "wizvera", "anysign",
                               "ipinside", "delfino", "magicline", "santa", "osquery", "elasticagent", "wazuh",
                               "commicrosoftautoupdate", "commicrosoftpowerlift", "commicrosoftwdav", "secureclient"]
    static let securityWord: Set<String> = ["eset", "drm", "mdm", "edr"]
    static let container = Pattern(#"^Library/(?:Containers/[^/]+/Data|Group Containers/[^/]+)/(.+)$"#)
    static let creativeCache = ["/Render Files/", "/Peaks Data/", "/CacheClip/", "/Media Cache Files/", "/Peak Files/"]
    /// Documented stores that their app or tool downloads or rebuilds by itself. User signals inside are checked first.
    static let knownStores = [
        #"^Library/Application Support/Steam/(appcache|depotcache|config/htmlcache|steamapps/(downloading|shadercache|temp|workshop/(downloads|content)))(/|$)"#,
        #"^Library/Application Support/minecraft/(assets|versions|libraries|runtime|webcache2?)(/|$)"#,
        #"^Library/Application Support/Epic/EpicGamesLauncher/(Data/Cache|VaultCache)(/|$)"#,
        #"^\.cargo/(registry/(src|index|cache)|git/(checkouts|db))(/|$)"#,
        #"^\.rustup/(downloads|tmp)(/|$)"#,
        #"^\.gradle/(caches|wrapper/dists|daemon|native)(/|$)"#,
        #"^\.android/(cache|build-cache)(/|$)"#,
        #"^\.cocoapods/repos(/|$)"#,
        #"^go/pkg/mod(/|$)"#,
        #"^Library/Caches/Homebrew(/|$)"#,
        #"^\.platformio/(packages|\.cache)(/|$)"#,
        #"^Library/Application Support/Zotero/Profiles/[^/]+/zotero/translators(/|$)"#,
        #"^Library/Application Support/Code/(CachedExtensionVSIXs|CachedProfilesData|CachedData|Crashpad)(/|$)"#,
        #"^Library/Caches/[^/]+\.ShipIt(/|$)"#,
        #"^Library/Caches/([^/]+/)?org\.sparkle-project\.Sparkle(/|$)"#,
    ].map(Pattern.init)
    /// Stores whose every name is a package's (`ca-certificates--2026-05-14`), so a name never means a secret there. Only
    /// Homebrew: other known stores can hold what people put in them (a Steam workshop folder with `wallet.dat` stays
    /// kept). Key files and password stores inside are still caught by the scanners' deep alarm names.
    static let packageNameStores = [Pattern(#"^Library/Caches/Homebrew(/|$)"#)]
    static let versionDir = Pattern(#"^\d+(\.\d+)+/?$"#)
    static let versionedInstall = Pattern(#"^[A-Za-z0-9_+-]*v?\d+(\.\d+)+[A-Za-z0-9_.+-]*/$"#)
    static let runtimeNames: Set<String> = ["node", "runtime", "runtimes", "versions", "sdk", "sdks", "toolchains", "engines"]
    static let settingsMark: Set<String> = ["options", "plugins", "keymaps", "codestyles", "templates", "libraries", "presets", "styles",
                                            "profiles", "scenes", "saves", "projects", "config", "configurations", "credentials", "settings"]
    static let reverseDNS = Pattern(#"^(com|org|net|io|dev|app|co|us|jp|kr|de|uk|me|ai|tv)\.[a-z0-9-]+\."#)
    static let extShape = Pattern(#"^\.[a-z0-9]{1,16}$"#)
    static let trailingVersion = Pattern(#"(\.\d+)+$"#)
    static let parenthesized = Pattern(#"\([^)]*\)"#)
    static let camelPieces = Pattern(#"[A-Z]+(?![a-z])|[A-Z]?[a-z]+|[0-9]+"#)

    static func decide(path: String, inside: String, beside: String, home: URL? = nil) -> (Decision, String) {
        let name = lastComponent(path)
        let hp = homePath(path)
        let ins = splitNames(inside).map(bare)
        let deep = deepNames(inside).map(bare)
        var bes = Set(splitNames(beside).map(bare))
        let low = deep.map { $0.lowercased() }
        let isFile = inside.hasPrefix("(a file") || inside.hasPrefix("(a single")
        let nameLow = name.lowercased()

        if creativeCache.contains(where: { ("/" + hp + "/").contains($0) }) || (hp.hasSuffix("Previews.lrdata") && !hp.hasSuffix("Smart Previews.lrdata")) {
            return (.regenerable, "creative app cache")
        }
        if hp.contains("com.apple.wallpaper/aerials") { return (.regenerable, "system asset") }
        if zones.contains(where: (hp + "/").hasPrefix) { return (.userData, "zone") }
        if securitySoftware(path) || ins.contains(where: securitySoftware) { return (.userData, "security or management software (keep)") }
        if inside.hasPrefix("(unreadable)") { return (.unknown, "") }
        if imageExt.contains(where: nameLow.hasSuffix) || low.contains(where: { n in imageExt.contains(where: n.hasSuffix) }) || inside.contains("disk image") {
            return (.userData, "image")
        }
        if deep.contains("device.plist") && deep.contains("data") { return (.userData, "simulator device") }
        let hasUser = low.contains { n in userExt.contains(where: n.hasSuffix) || dbExt.contains(where: n.hasSuffix) }
            || low.contains { n in userNames.contains(where: n.hasPrefix) }
        // Inside Library/Caches a database is the app's cache store; user signals in its names are still checked below.
        let hasUserDB = !hp.hasPrefix("Library/Caches/")
            && low.contains { ($0.hasSuffix(".sqlite") || $0.hasSuffix(".db")) && !$0.contains("cache") && !$0.contains("index") }
        if hasUser || hasUserDB { return (.userData, "user content inside") }
        if !packageNameStores.contains(where: { $0.search(hp) }), nameSignal(deep + [name]) == .secret { return (.userData, "secret-like name") }
        if ins.contains(where: { settingsMark.contains($0.lowercased()) }),
           !["Library/Caches/", "Library/Logs/", ".cache/"].contains(where: hp.hasPrefix) {
            return (.userData, "settings or user library inside")
        }
        if let home {
            let parent = home.appending(path: (path as NSString).deletingLastPathComponent)
            if let siblings = try? FileManager.default.contentsOfDirectory(atPath: parent.path(percentEncoded: false)) {
                bes.formUnion(siblings)
            }
        }
        if deep.contains("CURRENT") && deep.contains(where: { $0.hasPrefix("MANIFEST-") || $0.hasSuffix(".ldb") || $0 == "LOCK" }) {
            return (.userData, "database files inside")
        }
        if ("/" + hp).contains("/Service Worker/") {
            return name == "Database" ? (.userData, "chromium state") : (.regenerable, "chromium cache")
        }
        let profile = profileMark.intersection(bes).count >= 2
        if profile && chromiumUser.contains(name) { return (.userData, "chromium state") }
        if profile && chromiumRegen.contains(name) { return (.regenerable, "chromium cache") }
        if isFile && configExt.contains(where: nameLow.hasSuffix) && !("/" + hp).contains("/Logs/") { return (.userData, "settings file") }
        if isFile && isLogName(name) && (hp.hasPrefix("Library/") || hp.hasPrefix(".")) { return (.regenerable, "log file") }
        if hp.hasPrefix("Library/Logs/") || (!isFile && (nameLow == "log" || nameLow.hasSuffix("logs"))) {
            if isFile {
                if nameSignal([name]) != nil { return (.userData, "user-like name in a cache or log area") }
                return logExt.contains(extOf(name)) ? (.regenerable, "logs") : (.unknown, "")
            }
            return weak(cacheCheck(deep, logExt, hp), "logs", ownerLevel.search(hp) ? "" : name)
        }
        if hp != path && (hp == "tmp" || hp.hasPrefix("tmp/")) { return (.regenerable, "container temp") }
        if knownStores.contains(where: { $0.search(hp) }) { return (.regenerable, "known store") }
        if toolCaches.contains(where: hp.hasPrefix) || buildNames.contains(where: hp.hasSuffix) { return (.regenerable, "tool cache") }
        let named = ins.filter { !$0.hasPrefix(".") }
        if !named.isEmpty && named.allSatisfy(versionDir.search) && (hp.hasPrefix("Library/Application Support/") || hp.hasPrefix(".")) {
            return (.regenerable, "app-managed versions")
        }
        if runtimeNames.contains(nameLow) && !named.isEmpty
            && splitNames(inside).filter({ !$0.hasPrefix(".") }).allSatisfy(versionedInstall.search) {
            return (.regenerable, "runtime installs")
        }
        if hp.hasPrefix("Library/Caches/") || hp.hasPrefix(".cache/") {
            return weak(cacheCheck(isFile ? [name] : deep, cacheLikeExt, hp), "caches folder", ownerLevel.search(hp) ? "" : name)
        }
        if !isFile && nameLow.contains("cache") && (hp.hasPrefix("Library/") || hp.hasPrefix(".") || name.hasPrefix(".")) {
            return weak(cacheCheck(deep, cacheLikeExt, hp), "cache-named folder", name)
        }
        return (.unknown, "")
    }

    enum Signal: Sendable { case secret, user }
    enum Check: Sendable { case ok, user, unknown }

    static func securitySoftware(_ path: String) -> Bool {
        path.split(separator: "/", omittingEmptySubsequences: false).contains { part in
            let low = part.lowercased()
            let compact = String(low.unicodeScalars.filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) }.map(Character.init))
            return securityLong.contains(where: compact.contains) || !words(low).isDisjoint(with: securityWord)
        }
    }

    /// A strong log or crash extension wins over the words in its name.
    static func nameSignal(_ names: [String]) -> Signal? {
        var found: Signal?
        for n in names {
            let b = bare(n)
            if isLogName(b) { continue }
            let w = words(b)
            if !w.union(camelWords(b)).isDisjoint(with: secretWords) { return .secret }
            if !w.isDisjoint(with: softWords) { found = .user }
        }
        return found
    }

    /// `.ok` when every name looks like cache or log output, `.user` when any name signals the person's data, else `.unknown`.
    /// An empty list is `.unknown`: nothing checked is not the same as nothing found.
    static func cacheCheck(_ names: [String], _ allowed: Set<String>, _ hp: String) -> Check {
        if names.isEmpty { return .unknown }
        var verdict = Check.ok
        for n in names {
            let b = bare(n)
            if userDirs.contains(b.lowercased()) || nameSignal([b]) != nil { return .user }
            if b.lowercased().contains("cache") { continue }
            let e = extOf(b)
            if e == ".plist" && hp.hasPrefix("Library/Caches/") { continue }
            if !allowed.contains(e) { verdict = .unknown }
        }
        return verdict
    }

    static func weak(_ check: Check, _ why: String, _ name: String) -> (Decision, String) {
        var check = check
        if !name.isEmpty && (userDirs.contains(name.lowercased()) || nameSignal([name]) != nil) { check = .user }
        switch check {
        case .ok: return (.regenerable, why)
        case .user: return (.userData, "user-like name in a cache or log area")
        case .unknown: return (.unknown, "")
        }
    }

    // MARK: - Names

    /// A sandbox container mirrors the home folder, so its inner path is judged like the same path at home.
    static func homePath(_ path: String) -> String {
        container.firstGroup(path) ?? path
    }

    static func splitNames(_ text: String) -> [String] {
        parenthesized.replacingMatches(text, with: "").components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    static func deepNames(_ text: String) -> [String] {
        if text.hasPrefix("(a file") || text.hasPrefix("(a single") { return [] }
        let flat = text.replacingOccurrences(of: "(", with: ",").replacingOccurrences(of: ")", with: ",")
        var out: [String] = []
        for piece in flat.components(separatedBy: ",") {
            let n = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !n.isEmpty else { continue }
            out += n.components(separatedBy: "/").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        return out.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    static func bare(_ n: String) -> String { trimTrailingSlashes(n) }

    static func trimTrailingSlashes(_ s: String) -> String {
        var s = Substring(s)
        while s.hasSuffix("/") { s = s.dropLast() }
        return String(s)
    }

    static func lastComponent(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? path
    }

    /// A bundle id (com.apple.Foo) or a version name (node-v22.11.0-darwin-arm64) has no extension.
    static func extOf(_ name: String) -> String {
        let n = trailingVersion.replacingMatches(name.lowercased(), with: "")
        let withoutLeadingDots = n.drop(while: { $0 == "." })
        if !withoutLeadingDots.contains(".") || n.hasSuffix("/") || reverseDNS.search(n) { return "" }
        let e = "." + (n.components(separatedBy: ".").last ?? "")
        return extShape.search(e) ? e : ""
    }

    static func words(_ name: String) -> Set<String> {
        var out: Set<String> = []
        var current = ""
        for scalar in name.lowercased().unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                out.insert(current)
                current = ""
            }
        }
        if !current.isEmpty { out.insert(current) }
        return out
    }

    /// Splits AsidePasswordManager into aside, password, manager. Used for secret words only.
    static func camelWords(_ name: String) -> Set<String> {
        Set(camelPieces.matches(name).map { $0.lowercased() })
    }

    static func isLogName(_ name: String) -> Bool {
        strongExt.contains(extOf(name)) || name.lowercased().hasSuffix(".log.gz")
    }

    /// The "Facts" line the on-device model gets: kind, area, whether a browser profile sits beside, and the extensions
    /// among the names inside. Port of `prep.hints`.
    static func hints(path: String, inside: String, beside: String) -> String {
        var exts: [String: Int] = [:]
        for n in splitNames(inside) where n.contains(".") && !n.hasSuffix("/") {
            exts["." + (n.components(separatedBy: ".").last ?? "").lowercased(), default: 0] += 1
        }
        let bes = Set(splitNames(beside).map(bare))
        let kind = inside.hasPrefix("(a file") || inside.hasPrefix("(a single") ? "file" : "folder"
        let area = ["Library/Caches", "Library/Logs", "Library/Application Support", "Library/Containers", "Library/Group Containers",
                    "Library/Developer"].first(where: path.hasPrefix) ?? "home or dot folder"
        var parts = ["kind \(kind)", "area \(area)", "chromium profile beside: \(profileMark.intersection(bes).count >= 2 ? "yes" : "no")"]
        if !exts.isEmpty {
            parts.append("file types inside: " + exts.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", "))
        }
        return parts.joined(separator: "; ")
    }

    // MARK: - Listing

    /// What the rules read about an item, in the measured format: up to eight names inside (folders end in "/", each
    /// with up to three of its own names in parentheses) and up to six names beside it. Reads names and sizes only.
    static func listing(home: URL, relative: String) -> (inside: String, beside: String) {
        let full = home.appending(path: relative)
        let fullPath = full.path(percentEncoded: false)
        let parent = (fullPath as NSString).deletingLastPathComponent
        let own = (fullPath as NSString).lastPathComponent
        let beside = names(parent, excluding: own, limit: 6)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDirectory) else { return ("(unreadable)", beside) }
        guard isDirectory.boolValue else {
            let bytes = (try? FileManager.default.attributesOfItem(atPath: fullPath)[.size] as? Int64) ?? 0
            return ("(a file, \(max(1, bytes / 1024)) KB)", beside)
        }
        let base = names(fullPath, excluding: nil, limit: 8)
        if base.hasPrefix("(") { return (base, beside) }
        let parts = base.components(separatedBy: ", ").map { n -> String in
            guard n.hasSuffix("/") else { return n }
            let sub = names((fullPath as NSString).appendingPathComponent(String(n.dropLast())), excluding: nil, limit: 3)
            return sub.hasPrefix("(") ? n : n + " (" + sub + ")"
        }
        return (parts.joined(separator: ", "), beside)
    }

    /// Sorted by code points, like Python's `sorted` on the names macOS returns.
    static func names(_ folder: String, excluding: String?, limit: Int) -> String {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return "(unreadable)" }
        let sorted = entries.filter { $0 != excluding }.sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
        let out = sorted.prefix(limit).map { name -> String in
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: (folder as NSString).appendingPathComponent(name), isDirectory: &isDirectory)
            return isDirectory.boolValue ? name + "/" : name
        }
        return out.isEmpty ? "(empty)" : out.joined(separator: ", ")
    }
}

/// A compiled regular expression with Python's `search` and `match` semantics for these rules.
/// - Note: `NSRegularExpression` is immutable and documented as safe to use from several threads.
struct Pattern: @unchecked Sendable {
    let regex: NSRegularExpression

    init(_ pattern: String) {
        // swiftlint:disable:next force_try
        regex = try! NSRegularExpression(pattern: pattern)
    }

    func search(_ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    func firstGroup(_ text: String) -> String? {
        guard let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    func matches(_ text: String) -> [String] {
        regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    func replacingMatches(_ text: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}
