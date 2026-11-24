import Darwin
import Foundation

/// What a person uses this Mac for, told from where tools keep their files: each kind is a few home folders and app
/// names whose existence alone says the tool is installed or has been used here. Nothing is run and no folder is
/// opened, apart from listing the application folders' names.
/// - Note: It only changes what is shown: which clean-up areas are named, the simulator card, the disk summary. Scans
///   and verdicts never depend on it, so a wrong guess shows a line too many or too few and never deletes anything.
struct WorkEnvironment: Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case apple, android, web, python, jvm, go, rust, ruby, php, dotnet, containers, localAI, gameEngine, design, video, audio

        var title: String {
            switch self {
            case .apple: "iOS·macOS 개발"
            case .android: "Android 개발"
            case .web: "웹·Node.js"
            case .python: "Python·데이터"
            case .jvm: "Java·Kotlin"
            case .go: "Go"
            case .rust: "Rust"
            case .ruby: "Ruby"
            case .php: "PHP"
            case .dotnet: ".NET"
            case .containers: "컨테이너·가상 머신"
            case .localAI: "로컬 AI 모델"
            case .gameEngine: "게임 엔진"
            case .design: "디자인"
            case .video: "영상 편집"
            case .audio: "음악 제작"
            }
        }

        /// Folders relative to the home folder that the kind's tools create.
        var homeMarkers: [String] {
            switch self {
            case .apple: ["Library/Developer/Xcode", "Library/Developer/CoreSimulator"]
            case .android: [".android", "Library/Android/sdk"]
            case .web: [".npm", ".nvm", ".volta", ".bun", ".yarn", "Library/pnpm", "Library/Caches/Yarn"]
            case .python: [".pyenv", ".conda", "miniconda3", "anaconda3", ".local/share/uv", ".cache/uv", "Library/Caches/pip", ".jupyter"]
            case .jvm: [".m2", ".sdkman", ".ivy2"]
            case .go: ["go/pkg", "Library/Caches/go-build"]
            case .rust: [".cargo", ".rustup"]
            case .ruby: [".gem", ".rbenv", ".rvm"]
            case .php: [".composer", "Library/Caches/composer"]
            case .dotnet: [".nuget", ".dotnet"]
            case .containers: [".docker", ".orbstack", ".colima", ".lima", "Library/Containers/com.docker.docker"]
            case .localAI: [".ollama", ".lmstudio", ".cache/huggingface"]
            case .gameEngine: ["Library/Unity", "Library/Application Support/Unity", "Library/Application Support/Epic"]
            case .design: ["Library/Application Support/Figma", "Library/Application Support/com.bohemiancoding.sketch3",
                           "Library/Application Support/Blender", "Library/Application Support/Adobe/Common"]
            case .video: ["Library/Application Support/Blackmagic Design"]
            case .audio: []
            }
        }

        /// Starts of app names (without `.app`) in the application folders. A suite installs into a folder named like
        /// its app ("Adobe Photoshop 2026"), so folders count too.
        /// - Note: Apps a new Mac comes with (GarageBand, iMovie) are left out: having them says nothing.
        var appPrefixes: [String] {
            switch self {
            case .apple: ["Xcode"]
            case .android: ["Android Studio"]
            case .jvm: ["IntelliJ IDEA"]
            case .containers: ["Docker", "OrbStack", "UTM", "Parallels Desktop", "VMware Fusion"]
            case .localAI: ["Ollama", "LM Studio"]
            case .gameEngine: ["Unity Hub", "Unity", "Epic Games Launcher", "Godot"]
            case .design: ["Figma", "Sketch", "Blender", "Affinity", "Pixelmator Pro", "Adobe Photoshop", "Adobe Illustrator", "Adobe InDesign", "Adobe XD"]
            case .video: ["Final Cut Pro", "DaVinci Resolve", "Adobe Premiere Pro", "Adobe After Effects"]
            case .audio: ["Logic Pro", "Ableton Live", "FL Studio", "Pro Tools", "Cubase", "REAPER"]
            case .web, .python, .go, .rust, .ruby, .php, .dotnet: []
            }
        }
    }

    /// In `Kind.allCases` order.
    let kinds: [Kind]

    init(kinds: [Kind] = []) {
        self.kinds = Kind.allCases.filter(kinds.contains)
    }

    func has(_ kind: Kind) -> Bool { kinds.contains(kind) }

    /// The kinds by name, for one line on the screen; empty when none was found.
    var summary: String { kinds.map(\.title).joined(separator: " · ") }

    /// - Parameters:
    ///   - applications: the folders whose entries are app names; nil reads `/Applications` and `~/Applications`.
    ///   - exists: whether a path exists, without following a link at its end; tests replace it.
    static func detect(home: URL, applications: [String]? = nil, exists: (String) -> Bool = WorkEnvironment.exists) -> WorkEnvironment {
        let homePath = home.path(percentEncoded: false)
        let appNames = applications ?? installedAppNames(in: ["/Applications", homePath + "/Applications"])
        let found = Kind.allCases.filter { kind in
            kind.homeMarkers.contains { exists((homePath as NSString).appendingPathComponent($0)) }
                || appNames.contains { name in kind.appPrefixes.contains { name.hasPrefix($0) } }
        }
        return WorkEnvironment(kinds: found)
    }

    /// The entry names of these folders, `.app` cut off; a folder that cannot be read gives none.
    static func installedAppNames(in folders: [String]) -> [String] {
        folders.flatMap { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] }
            .map { $0.hasSuffix(".app") ? String($0.dropLast(4)) : $0 }
    }

    /// `lstat`, so a marker that is a link counts as itself and its target is never read.
    static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }
}
