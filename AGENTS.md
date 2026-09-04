# Beet Code — Agent Onboarding

This is a native macOS coding agent (Swift 6 / SwiftUI / MLX + BYOK).

## Before changing anything

1. Read `docs/APP-REPORT.md` — the full structure/capabilities/API/security
   report for this codebase (written for agent reviewers).
2. Read `docs/COMPARISON.md` for known feature gaps vs OpenCode/OpenClaude,
   and `docs/COMPOSER-DESIGN.md` for the composer rationale.
3. Build & test first:
   ```sh
   xcodegen generate   # required after adding/removing files
   xcodebuild -project BeetCode.xcodeproj -scheme BeetCode \
     -destination 'platform=macOS' -derivedDataPath .derived test
   ```
   Run both `BeetCodeTests` and `BeetCodeRemoteIOSTests`; see the Apple apps
   workflow for simulator and Release build gates. Set `DEVELOPER_DIR` to a full
   Xcode installation. Forward it as `TEST_RUNNER_DEVELOPER_DIR` when testing:
   Ship Center integration tests invoke Xcode from inside the test host.
   Do not regenerate the project while a build is running.

## Architecture in 30 seconds

- `AppState` (MainActor) → `AgentSessionController` → `AgentLoop` (actor) →
  `PermissionGate` → `ToolExecutor` → `AgentTool`s.
- Engines behind `LLMEngine`; `EngineRouter` switches local MLX / local GGUF
  (embedded llama-server) / remote BYOK (OpenAI/DeepSeek/LongCat/Alibaba/
  Gemini/OpenRouter/Anthropic/Custom).
- `Workspace` = canonical realpath confinement; `ShellRunner` = posix_spawn
  process groups; `GitCheckpointer` = approval-before-mutation snapshots.
- Sessions encrypted (Keychain key, cached); memory facts/summaries per
  workspace; events stream via AsyncStream<AgentEvent>.
- Models drive the in-app browser (`browser_*` tools → `BrowserController`)
  and the built-in simulator (`sim_*` tools → argent; `sim_build_run` =
  build → install → launch → screenshot → describe in one call).
  `PromptBuilder.capabilityGuidance` teaches models WHEN to use them
  (visual verify loops) — keep it in sync when adding tool families.

## Rules

- Erasable Swift syntax only; NSLock only inside sync helpers (async
  contexts reject lock()/unlock()).
- New tools: implement `AgentTool` (honest `risk` + JSON `schemaText`) and
  register in `AgentSessionController.defaultTools`.
- New settings: `SettingsStore` key + default + SettingsView + pass into
  `AgentLoop.Configuration`.
- Tests: `FakeLLMEngine` / `FixtureHub` / `TempWorkspace`; never real dirs.
- Run `xcodegen generate` after any file add/remove.

## Quick links

- Report: `docs/APP-REPORT.md`
- Gaps: `docs/COMPARISON.md`
- Composer design: `docs/COMPOSER-DESIGN.md`
- Acceptance: `docs/ACCEPTANCE-v0.2.md`