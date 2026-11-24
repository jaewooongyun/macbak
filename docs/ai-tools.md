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

## 기기 AI 작업 더하기 (2026-11-24)

기기 모델(FoundationModels)을 부르는 기능은 모두 `ModelSlot.shared.run(_:deadline:_:)`을 거칩니다. 앱 전체에서 한 번에 하나씩 돌고, `.high`(줄이 결과를 기다리는 탐색)가 `.low`(디스크 요약, 사람이 누른 묻기)보다 먼저입니다. 모델에게 경로나 명령을 만들게 하지 않고, 코드가 만든 선택지(`@Generable` 열거형) 가운데서 고르게 합니다. 화면에 보이는 문장과 숫자는 코드가 씁니다. 모델에게 주는 지시문은 영어로 씁니다. 정기 정리와 메뉴 막대에서는 새 기기 AI 작업을 부르지 않습니다.
