import Foundation
import Testing
@testable import Macbak

/// A `KERN_PROCARGS2` buffer: argc, executable path, NUL padding, the arguments, then an environment variable.
private func procargs(executable: String, _ arguments: [String]) -> ArraySlice<UInt8> {
    var bytes = withUnsafeBytes(of: Int32(arguments.count)) { Array($0) }
    bytes += Array(executable.utf8) + [0, 0, 0]
    for argument in arguments { bytes += Array(argument.utf8) + [0] }
    bytes += Array("HOME=/Users/someone".utf8) + [0]
    return bytes[...]
}

@Test func claudeCodeSessionsAreSeparatedFromHelpersByArgv0() {
    let path = "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe"
    #expect(AIProcessClassifier.tool(for: ProcessFacts(name: "claude.exe", path: path)) == .claudeCode)
    let rule = AITool.claudeCode.process
    #expect(rule.isSession(argv0: "claude", parentIsSameTool: true))
    #expect(!rule.isSession(argv0: "claude bg-spare", parentIsSameTool: false))
    #expect(!rule.isSession(argv0: nil, parentIsSameTool: false))
}

@Test func bundledCodexBelongsToChatGPT() {
    let bundled = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
    #expect(AIProcessClassifier.tool(for: ProcessFacts(name: "codex", path: bundled)) == .chatGPT)
    #expect(AIProcessClassifier.tool(for: ProcessFacts(name: "codex", path: "/opt/homebrew/bin/codex")) == .codex)
    #expect(AIProcessClassifier.tool(for: ProcessFacts(name: "Finder", path: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder")) == nil)
}

@Test func geminiIsFoundByTheScriptItRunsOnNode() {
    // `gemini --model …` through its `#!/usr/bin/env -S node --no-warnings=DEP0040` shebang, as `ps` showed it.
    let node = "/opt/homebrew/Cellar/node/26.4.0/bin/node"
    let parsed = ProcessArguments.parse(procargs(executable: node, ["node", "--no-warnings=DEP0040", "/opt/homebrew/bin/gemini", "--model", "secret-value"]))
    #expect(parsed.argv0 == "node")
    #expect(parsed.script == "/opt/homebrew/bin/gemini")
    #expect(AIProcessClassifier.tool(for: ProcessFacts(name: "node", path: node, argv0: parsed.argv0, script: parsed.script)) == .geminiCLI)
    #expect(AIProcessClassifier.tool(for: ProcessFacts(name: "node", path: node)) == nil)
}

@Test func argumentsAfterArgv0AreNotReadForNativeTools() {
    let parsed = ProcessArguments.parse(procargs(executable: "/opt/homebrew/bin/claude", ["claude", "/private/token-file", "--resume"]))
    #expect(parsed.argv0 == "claude")
    #expect(parsed.script == nil)
}

@Test func relaunchedChildIsNotASecondSession() {
    let rule = AITool.geminiCLI.process
    #expect(rule.isSession(argv0: "node", parentIsSameTool: false))
    #expect(!rule.isSession(argv0: "node", parentIsSameTool: true))
    #expect(!AITool.chatGPT.process.isSession(argv0: nil, parentIsSameTool: false))
}

@Test func catalogIdsAreUniqueAndSharedFoldersPointAtRealTools() {
    let ids = AITool.catalog.map(\.id)
    #expect(Set(ids).count == ids.count)
    for area in AITool.catalog.flatMap(\.cleanable) {
        #expect(area.sharedWith.allSatisfy { AITool.with(id: $0) != nil })
    }
}

@Test func jobScratchFollowsTheJobState() {
    let store = AITool.claudeCode.jobs!
    let day = 86_400.0
    #expect(evaluate(AIStorageRules.jobScratchEvidence(state: "working", store: store, newestFileAge: 30 * day)!).status == .protected)
    #expect(evaluate(AIStorageRules.jobScratchEvidence(state: "blocked", store: store, newestFileAge: 30 * day)!).status == .protected)
    #expect(evaluate(AIStorageRules.jobScratchEvidence(state: "done", store: store, newestFileAge: 8 * day)!).status == .review)
    #expect(AIStorageRules.jobScratchEvidence(state: "done", store: store, newestFileAge: 1 * day) == nil)
    #expect(evaluate(AIStorageRules.jobScratchEvidence(state: nil, store: store, newestFileAge: 30 * day)!).status == .protected)
}

@Test func unknownRunningStateNeverCountsAsUnused() {
    #expect(AIStorageRules.inUse(nil, any: ["claude-app"]) == nil)
    #expect(evaluate(AIStorageRules.evidence(for: .cache, inUse: AIStorageRules.inUse(nil, any: ["claude-app"]))).status == .protected)
    #expect(AIStorageRules.inUse(["chatgpt"], any: ["codex", "chatgpt"]) == true)
    #expect(AIStorageRules.inUse([], any: ["claude-app"]) == false)
    #expect(evaluate(AIStorageRules.evidence(for: .shared, inUse: nil)).status == .protected)
}

@Test func sessionLogsCountOneFilePerConversation() throws {
    let home = FileManager.default.temporaryDirectory.appending(path: "macbak-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    for path in [".claude/projects/app/a.jsonl", ".claude/projects/app/a-uuid/subagents/agent-1.jsonl",
                 ".gemini/tmp/app/chats/session-1.json", ".gemini/tmp/app/logs.json", ".gemini/tmp/bin/rg",
                 ".codex/sessions/2026/11/02/rollout-1.jsonl"] {
        let url = home.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: url)
    }
    let claude = AITool.claudeCode.sessions!.stats(home: home, now: .now)
    #expect(claude.logs == 1 && claude.nestedLogs == 1 && claude.projects == 1 && claude.within5m == 1)
    let gemini = AITool.geminiCLI.sessions!.stats(home: home, now: .now)
    #expect(gemini.logs == 1 && gemini.nestedLogs == 0 && gemini.projects == 1)
    // Codex keeps date folders: deep files are its ordinary logs, not nested ones.
    let codex = AITool.codex.sessions!.stats(home: home, now: .now)
    #expect(codex.logs == 1 && codex.nestedLogs == 0)
}

@Test func oldFilesStayProtectedWhenOpenFilesCouldNotBeRead() {
    #expect(evaluate(AIStorageRules.evidence(for: .stale(days: 30), inUse: nil)).status == .protected)
    #expect(evaluate(AIStorageRules.evidence(for: .stale(days: 30), inUse: false)).status == .ready)
}
