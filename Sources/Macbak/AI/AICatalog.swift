import Foundation

/// The company behind a tool. Charts color by vendor, so a new tool from a known vendor needs no new color.
enum AIVendor: String, CaseIterable, Sendable {
    case anthropic, openAI, google, cursor, local, other

    var name: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openAI: "OpenAI"
        case .google: "Google"
        case .cursor: "Cursor"
        case .local: "로컬 모델"
        case .other: "기타"
        }
    }
}

/// Everything Macbak knows about one AI tool, written as data.
/// - Important: Supporting a new tool means adding one entry to `catalog`; no other file names a tool.
///   Only metadata is read: process names and paths, file names, sizes and dates — never contents.
struct AITool: Identifiable, Sendable {
    let id: String
    let name: String
    let vendor: AIVendor
    let symbol: String
    let process: ProcessRule
    /// Where it keeps conversation logs, if anywhere.
    var sessions: SessionLog?
    /// Where it keeps background jobs, if it runs any.
    var jobs: JobStore?
    /// Every folder it owns, summed for its storage total.
    var footprint: [StoragePath] = []
    /// Folders inside the footprint that may be cleaned.
    var cleanable: [StorageArea] = []
}

extension AITool: Hashable {
    static func == (lhs: AITool, rhs: AITool) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// How to recognize a tool's processes.
struct ProcessRule: Sendable {
    /// App bundle names, such as "Claude.app". Checked before every other rule, and the outermost bundle in the path
    /// wins, because apps ship CLIs of their own (the ChatGPT app carries a `codex`).
    var bundles: [String] = []
    /// Executable names, or script names for tools that run on a script runtime such as node.
    var names: [String] = []
    /// Fragments of package install paths, such as "/@anthropic-ai/claude-code/".
    var installPaths: [String] = []
    var sessions: SessionRule = .none
}

/// Which of a tool's processes are user sessions rather than helpers.
enum SessionRule: Sendable {
    /// An app: all its processes are parts of one app.
    case none
    /// Processes whose argv[0] is this name; helpers call themselves something else.
    case argv0(String)
    /// Processes whose parent is not the same tool, for CLIs that relaunch themselves in a child process.
    case rootProcess
}

/// Where a tool keeps conversation logs. Only file names and modification times are read.
struct SessionLog: Sendable {
    enum Layout: Sendable {
        /// `root/<project>/<folder>/*.ext`. Logs deeper inside, such as subagent logs, are counted apart.
        case perProject(folder: String = "")
        /// Any depth under `root`, such as date folders.
        case anywhere
    }

    /// Relative to the home folder.
    let root: String
    let fileExtension: String
    let layout: Layout
}

/// Background jobs, one folder each, with a JSON state file of which only `field` is read.
struct JobStore: Sendable {
    let root: String
    var stateFile = "state.json"
    var field = "state"
    var running: Set<String> = ["working"]
    /// Alive but paused, such as waiting for the user or a usage limit.
    var waiting: Set<String> = ["blocked"]
    var finished: Set<String> = ["done"]
    /// Scratch files inside each job folder.
    var scratch = "tmp"
    /// Where the tool keeps one file per live session (`*.json`, naming its job as `jobId`), relative to the home.
    var sessions: String?

    /// Running or waiting: its files are still in use.
    func isAlive(_ state: String?) -> Bool {
        state.map { running.contains($0) || waiting.contains($0) } ?? false
    }
}

enum StoragePath: Sendable {
    case home(String)
    case temporary(String)

    func url(home: URL) -> URL {
        switch self {
        case .home(let path): home.appending(path: path)
        case .temporary(let path): URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: path)
        }
    }

    /// Short form for row details: "~/.codex/cache", "임시 폴더/orca-computer-use".
    var display: String {
        switch self {
        case .home(let path): "~/" + path.replacingOccurrences(of: "Library/Application Support/", with: "Application Support/")
        case .temporary(let path): "임시 폴더/" + path
        }
    }
}

/// A group of folders that may be cleaned, and what their contents allow.
struct StorageArea: Sendable {
    enum Kind: Sendable {
        /// The owner rebuilds it: ready while the owner is not running.
        case cache
        /// Downloaded again when needed: the user decides.
        case download
        /// Logs and scratch files nothing reads after `days`.
        case stale(days: Double)
        /// Used by several tools; whether one is using it needs an open-files check that does not exist yet, so it stays protected.
        case shared
    }

    let id: String
    let name: String
    let symbol: String
    let paths: [StoragePath]
    let kind: Kind
    /// Other tools that use these folders too, by id.
    var sharedWith: [String] = []
    /// Replaces the generated explanation in the row detail.
    var note: String?
}

// MARK: - Catalog

extension AITool {
    static let catalog: [AITool] = [claudeCode, claudeApp, codex, chatGPT, geminiCLI, cursor, ollama, lmStudio, aside, orca]

    static func with(id: String) -> AITool? { catalog.first { $0.id == id } }

    static let claudeCode = AITool(
        id: "claude-code", name: "Claude Code", vendor: .anthropic, symbol: "terminal",
        process: ProcessRule(names: ["claude", "claude.exe"], installPaths: ["/@anthropic-ai/claude-code/"], sessions: .argv0("claude")),
        sessions: SessionLog(root: ".claude/projects", fileExtension: "jsonl", layout: .perProject()),
        jobs: JobStore(root: ".claude/jobs", sessions: ".claude/sessions"),
        footprint: [.home(".claude"), .home("Library/Caches/claude-cli-nodejs")],
        cleanable: [
            StorageArea(id: "mcp-logs", name: "오래된 MCP 서버 로그", symbol: "doc.text",
                        paths: [.home("Library/Caches/claude-cli-nodejs")], kind: .stale(days: 7)),
        ]
    )

    static let claudeApp = AITool(
        id: "claude-app", name: "Claude 앱", vendor: .anthropic, symbol: "bubble.left.and.text.bubble.right",
        process: ProcessRule(bundles: ["Claude.app"]),
        footprint: [.home("Library/Application Support/Claude"), .home("Library/Caches/com.anthropic.claudefordesktop")],
        cleanable: [
            StorageArea(id: "web-cache", name: "Claude 앱 화면 캐시", symbol: "bubble.left.and.text.bubble.right",
                        paths: [.home("Library/Application Support/Claude/Cache"), .home("Library/Application Support/Claude/Code Cache"),
                                .home("Library/Caches/com.anthropic.claudefordesktop")], kind: .cache),
            StorageArea(id: "vm", name: "Claude 앱 VM 이미지", symbol: "shippingbox",
                        paths: [.home("Library/Application Support/Claude/vm_bundles")], kind: .download),
        ]
    )

    static let codex = AITool(
        id: "codex", name: "Codex", vendor: .openAI, symbol: "terminal",
        process: ProcessRule(names: ["codex"], installPaths: ["/@openai/codex/"], sessions: .rootProcess),
        sessions: SessionLog(root: ".codex/sessions", fileExtension: "jsonl", layout: .anywhere),
        footprint: [.home(".codex")],
        cleanable: [
            StorageArea(id: "scratch", name: "Codex 임시 파일과 캐시", symbol: "terminal",
                        paths: [.home(".codex/.tmp"), .home(".codex/cache")], kind: .cache, sharedWith: ["chatgpt"]),
        ]
    )

    /// The ChatGPT app is the Codex app (`com.openai.codex`); it shares `~/.codex` with the CLI.
    static let chatGPT = AITool(
        id: "chatgpt", name: "ChatGPT 앱", vendor: .openAI, symbol: "bubble.left.and.text.bubble.right",
        process: ProcessRule(bundles: ["ChatGPT.app"]),
        footprint: [.home("Library/Application Support/Codex"), .home("Library/Caches/Codex"), .home("Library/Caches/com.openai.codex")],
        cleanable: [
            StorageArea(id: "web-cache", name: "ChatGPT 앱 화면 캐시", symbol: "bubble.left.and.text.bubble.right",
                        paths: [.home("Library/Application Support/Codex/Cache"), .home("Library/Application Support/Codex/Code Cache"),
                                .home("Library/Caches/Codex"), .home("Library/Caches/com.openai.codex")], kind: .cache),
        ]
    )

    /// Runs on node, so it is found by its script path; it relaunches itself in a child process, hence `rootProcess`.
    static let geminiCLI = AITool(
        id: "gemini-cli", name: "Gemini CLI", vendor: .google, symbol: "terminal",
        process: ProcessRule(names: ["gemini"], installPaths: ["/@google/gemini-cli/"], sessions: .rootProcess),
        sessions: SessionLog(root: ".gemini/tmp", fileExtension: "json", layout: .perProject(folder: "chats")),
        footprint: [.home(".gemini")]
    )

    static let cursor = AITool(id: "cursor", name: "Cursor", vendor: .cursor, symbol: "chevron.left.forwardslash.chevron.right",
                               process: ProcessRule(bundles: ["Cursor.app"]))
    static let ollama = AITool(id: "ollama", name: "Ollama", vendor: .local, symbol: "cpu",
                               process: ProcessRule(bundles: ["Ollama.app"], names: ["ollama"]), footprint: [.home(".ollama")])
    static let lmStudio = AITool(id: "lm-studio", name: "LM Studio", vendor: .local, symbol: "cpu",
                                 process: ProcessRule(bundles: ["LM Studio.app"]))
    static let aside = AITool(id: "aside", name: "Aside", vendor: .other, symbol: "bubble.left.and.text.bubble.right",
                              process: ProcessRule(bundles: ["Aside.app"]))
    static let orca = AITool(
        id: "orca", name: "Orca", vendor: .other, symbol: "square.stack.3d.down.right",
        process: ProcessRule(bundles: ["Orca.app"]),
        footprint: [.home("Library/Application Support/orca")],
        cleanable: [
            StorageArea(id: "computer-use-shots", name: "컴퓨터 사용 도구의 임시 스크린숏", symbol: "camera.viewfinder",
                        paths: [.temporary("orca-computer-use")], kind: .stale(days: 1)),
        ]
    )

    /// Caches no single tool owns.
    static let sharedCaches: [StorageArea] = [
        StorageArea(id: "npx", name: "MCP 서버 패키지 캐시", symbol: "puzzlepiece.extension", paths: [.home(".npm/_npx")], kind: .shared),
        StorageArea(id: "huggingface", name: "Hugging Face 모델 캐시", symbol: "cpu", paths: [.home(".cache/huggingface")], kind: .shared),
        StorageArea(id: "uv", name: "uv 패키지 캐시", symbol: "shippingbox", paths: [.home(".cache/uv")], kind: .shared,
                    note: "Serena 같은 도구의 실행 환경이 들어 있을 수 있음"),
        StorageArea(id: "playwright", name: "Playwright 브라우저", symbol: "safari", paths: [.home("Library/Caches/ms-playwright")], kind: .shared),
    ]
}
