import Foundation

/// A finished AI job's scratch folder, gone only when the job is done, nothing in it changed for the Settings age, and
/// no live session names the job.
/// - Important: Only a session's `*.json` is read, never the `.key` files beside it, and every read goes through
///   `Inputs.read`.
enum JobScratch {
    /// The catalog store `tmp` belongs to, when it is exactly `<home>/<store root>/<job id>/<scratch>`.
    static func store(of tmp: URL, home: URL) -> JobStore? {
        let jobs = ProjectDiscovery.key(tmp.deletingLastPathComponent().deletingLastPathComponent())
        return AITool.catalog.compactMap(\.jobs).first { store in
            tmp.lastPathComponent == store.scratch && jobs == ProjectDiscovery.key(home.appending(path: store.root))
        }
    }

    static func refusal(_ tmp: URL, _ inputs: TargetGrant.Inputs) -> (String?, TreeFacts) {
        guard let home = inputs.home, let store = store(of: tmp, home: home) else { return ("AI 작업의 임시 폴더가 아닙니다", TreeFacts()) }
        let job = tmp.deletingLastPathComponent()
        let stateFile = job.appending(path: store.stateFile)
        guard let data = inputs.read(stateFile), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let state = object[store.field] as? String else { return ("작업 상태를 읽지 못했습니다", TreeFacts()) }
        guard store.finished.contains(state) else { return ("끝난 작업이 아닙니다", TreeFacts()) }
        let age = inputs.ages.seconds(.aiJobScratch)
        guard let stated = (try? stateFile.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else {
            return ("작업 상태를 읽지 못했습니다", TreeFacts())
        }
        if inputs.now.timeIntervalSince(stated) < age { return ("최근에 끝난 작업입니다", TreeFacts()) }
        let facts = TreeWalk.inspect(tmp, budget: .seconds(60), until: inputs.deadline)
        guard facts.isComplete else { return ("다 훑지 못했습니다", facts) }
        guard let newest = facts.newest else { return ("빈 임시 폴더입니다", facts) }
        if inputs.now.timeIntervalSince(newest) < age { return ("최근에 바뀐 파일이 있습니다", facts) }
        if let sessions = store.sessions {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: home.appending(path: sessions).path(percentEncoded: false)) else {
                return ("세션 목록을 읽지 못했습니다", facts)
            }
            for name in names where name.hasSuffix(".json") {
                // A session file that cannot be read or parsed may point at this job.
                guard let data = inputs.read(home.appending(path: sessions).appending(path: name)),
                      let session = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    return ("세션 기록을 읽지 못했습니다", facts)
                }
                if session["jobId"] as? String == job.lastPathComponent {
                    return ("살아 있는 세션이 이 작업을 가리킵니다", facts)
                }
            }
        }
        guard let open = inputs.open else { return ("열린 파일을 확인하지 못했습니다", facts) }
        if open.anyOpen(under: job.path(percentEncoded: false)) { return ("지금 쓰는 파일이 있습니다", facts) }
        return (nil, facts)
    }
}

/// Rows for finished AI jobs' scratch folders, for the expanded scan only; the AI storage screen lists them, unchosen.
enum JobScratchScanner {
    static func scan(_ context: ScanContext, judge: ProjectOutputScanner.Judge = TargetGrant.evaluate) -> [CleanupCandidate] {
        AITool.catalog.flatMap { tool -> [CleanupCandidate] in
            guard let store = tool.jobs else { return [] }
            return store.jobFolders(home: context.home).compactMap { job in
                let tmp = job.appending(path: store.scratch)
                guard FileManager.default.fileExists(atPath: tmp.path(percentEncoded: false)) else { return nil }
                let grant = TargetGrant(kind: .jobScratch, path: tmp)
                let judged = judge(grant, .init(now: context.now, ages: context.ages, open: context.openFiles, borrowers: [], reprove: false,
                                                home: context.home, deadline: context.deadline))
                guard judged.facts.bytes >= ScanSupport.minimumBytes || !judged.facts.isComplete else { return nil }
                var evidence = Evidence(verified: true, inUse: false, regenerable: false, userData: true)
                evidence.protectedReason = judged.refusal
                let path = tmp.path(percentEncoded: false)
                var row = CleanupCandidate(
                    id: "jobs." + ProjectDiscovery.key(tmp), name: "끝난 \(tool.name) 작업 \(job.lastPathComponent)의 임시 파일",
                    detail: ScanSupport.display(path, home: context.home) + " · " + ScanSupport.ago(judged.facts.newest, now: context.now),
                    symbol: "doc.on.doc", bytes: judged.facts.bytes, evidence: evidence, lowerBound: !judged.facts.isComplete,
                    targets: [CleanupTarget(path: tmp, root: job, identity: FileIdentity.of(path), action: .removeItem, grant: grant)],
                    lastUsed: judged.facts.newest)
                row.manualOnly = true
                row.guards.watchPaths = [job]
                return row
            }
        }
    }
}
