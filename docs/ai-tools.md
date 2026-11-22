# AI 도구 추가하기

AI 도구 정보는 `Sources/Macbak/AI/AICatalog.swift`의 `AITool.catalog` 한 곳에만 있습니다. 새 도구를 지원하려면 항목 하나만 더하면 됩니다. 다른 파일은 도구 이름을 모릅니다.

```swift
static let geminiCLI = AITool(
    id: "gemini-cli", name: "Gemini CLI", vendor: .google, symbol: "terminal",
    process: ProcessRule(names: ["gemini"], installPaths: ["/@google/gemini-cli/"], sessions: .rootProcess),
    sessions: SessionLog(root: ".gemini/tmp", fileExtension: "json", layout: .perProject(folder: "chats")),
    footprint: [.home(".gemini")]
)
```

| 필드 | 하는 일 |
|---|---|
| `vendor` | 차트 색과 AI 활동의 제조사 카드 |
| `process` | 프로세스 알아보기 |
| `sessions` | 대화 기록 위치 |
| `jobs` | 백그라운드 작업 |
| `footprint` | 저장 공간 합계 |
| `cleanable` | 정리 후보 |

- `process`: 앱 번들 이름(`Claude.app`)이 가장 먼저이고, 경로에서 바깥 번들이 이깁니다. 그래서 ChatGPT 앱 안의 `codex`는 ChatGPT로 분류됩니다. node처럼 이름으로는 알 수 없는 런타임은 스크립트 경로로 알아봅니다. 세션은 `argv0`(Claude Code처럼 도우미가 다른 이름을 쓸 때) 또는 `rootProcess`(Gemini처럼 자기 자신을 자식으로 다시 띄울 때)로 셉니다.
- `sessions`: `perProject`는 `root/<프로젝트>/<폴더>/*.ext`이고, 더 깊은 파일(Claude의 서브에이전트 기록)은 따로 셉니다. `anywhere`는 날짜 폴더처럼 깊이와 관계없이 셉니다. 기록이 있으면 "90일 넘은 대화 기록" 후보가 자동으로 생깁니다.
- `cleanable`: `cache`(도구가 다시 만듦, 도구가 꺼져 있을 때만 정리 가능), `download`(다시 내려받음, 골라서 지울 것), `stale(days:)`(며칠 지난 로그·임시 파일), `shared`(여러 도구가 함께 써서 보호).
