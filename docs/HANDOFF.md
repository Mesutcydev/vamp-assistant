# Handoff — audit & fix session (2026-09-11)

Continuation notes for a new agent session. This session audited the app
(macOS core + UI + iOS remote), fixed a large batch of verified findings, and
left a specific queue of remaining work. Nothing was committed to git; all
changes are in the working tree.

> 2026-09-12 continuation: backlog items 1–5 below are DONE (see
> "Fixed 2026-09-12"). The remaining queue is at the bottom. All suites green:
> 962 macOS unit / 13 UI / 31 iOS.

## Ground rules & commands

- Xcode: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`
  (Xcode beta is the only install). Do not regenerate the project while a
  build runs. `xcodegen generate` only after adding/removing files.
- macOS unit tests:
  ```sh
  xcodebuild -project BeetCode.xcodeproj -scheme BeetCode \
    -destination 'platform=macOS' -derivedDataPath .derived test \
    -only-testing:BeetCodeTests
  ```
- macOS UI tests: same command with `-only-testing:BeetCodeUITests` (~3 min).
- iOS remote tests:
  ```sh
  xcodebuild -project BeetCode.xcodeproj -scheme BeetCodeRemoteIOS \
    -destination 'platform=iOS Simulator,id=8D051CF7-FD51-4720-A30C-D08C8DA05AEB' \
    -derivedDataPath .ios-test-derived test -only-testing:BeetCodeRemoteIOSTests
  ```
- **Current status (all green):** 962 macOS unit (10 skipped) / 13 UI / 31 iOS.
- Debug app: `.derived/Build/Products/Debug/Vamp Assistant.app`. Its real
  code lives in `Contents/MacOS/Vamp Assistant.debug.dylib` (59 KB launcher);
  grep/strings that dylib to confirm a fix is in a build.
- Never commit unless the user explicitly asks.

## Environment gotchas learned the hard way

- **TCC**: a Debug build cannot read `~/Downloads`, `~/Desktop`, or
  `~/Documents` unless the folder was chosen through the app's `NSOpenPanel`.
  Setting `lastWorkspacePath` directly to such a path makes every tool fail
  with `Operation not permitted` and the model loops. Use e.g.
  `/Users/m/beetcode-website-demo` for live tests. The app now appends a
  "re-open the folder / System Settings → Files and Folders" hint to such
  failures (`ToolExecutor.addingPrivacyHint`).
- Live demo workspace: `/Users/m/beetcode-website-demo/index.html` — the
  MiniCPM5-2B-generated animated background page (verified rendering +
  two-frame animation diff in the in-app browser).
- The running app is `Vamp Assistant.app`; relaunch with `open -na <path>`.
  UI automation via System Events works; buttons expose `help`; some SwiftUI
  elements merge accessibility frames.

## Fixed 2026-09-12 (backlog items 1–5; do not redo)

Checkpoint pin refs
- `SessionCheckpoint.refName: String?` (optional; old records decode).
  `GitCheckpointer.snapshot` stores the pin ref it creates.
- `GitCheckpointer.deletePinRef` / `prunePins(checkpoints:workspacePath:)`
  delete refs on session deletion (called from `SessionStore.delete`, outside
  the store lock, best-effort). Ref names are prefix-validated so a crafted
  record cannot delete `refs/heads/*`.
- `GitCheckpointer.sweepOrphanedPins(workspacePath:referencedTreeSHAs:)` matches
  refs by pinned tree, so legacy pre-refName refs survive while their session
  exists. `AppState.sweepOrphanedCheckpointRefs()` runs it once at launch,
  off-main, after waiting for any active run (so a fresh, not-yet-persisted
  checkpoint can never be swept); includes pending failed saves.

iOS remote
- `AgentSessionController.remoteRunFullAccess` reports the raw flag; the Mac
  no longer folds Auto into `fullAccess` in `sessionDetail`. iOS
  `RemoteStore.isFullAccessSelected` derives AUTO/FULL from both flags.
- `RemoteStore.revoke()` returns `.revoked` / `.unreachable`; Settings offers
  "Forget Locally" on an unreachable Mac (no more dead-end error).
- Bot steer/approve/answer handlers are async and route through
  `BotRunCoordinator.deliverCommand`; the host returns 202 only after runtime
  acceptance, so an offline/rejected command keeps the phone's input.

Composer / settings UI
- `ChatInputWell` (`ChatFrame.swift`) measures its width and splits the key
  row into two rows below 620 pt. Verified at 520×700 (wrapped) and
  1320×856 (unchanged). `ChatFrameMetrics.keyRowCompactWidth`.
- `InstrumentSegmentedControl` (`DesignSystem.swift`) is now a native
  segmented `Picker` (custom keys merged their AX frames; XCUITest always hit
  key 1). Provider-directory UI test restored:
  `testProviderDirectorySegmentOpensProviderBrowser` (queries
  `app.radioButtons["Providers"]`).
- Workspace actions from the retired chat header (review changed files, git
  status, undo last checkpoint, export task bundle) are back in
  `MainWindowView.moreActionsMenu`, posting the existing notifications.
  `ChatHeaderView` / `ChatHeaderActions` / `ChatPhaseBadge` and ChatView's
  `phaseLabel` / `phaseTint` are still present but unused.

New environment gotchas
- Toolbar-attached `InstrumentMenu` popovers are invisible to XCUITest
  (`app.windows == 1`, `app.popovers == 0` while open). Do not write UI tests
  that open the toolbar overflow; the composer's popovers (Chats) do work.
- UI tests can fail in bulk when a TCC dialog (e.g. runner asking for
  Downloads access) is pending: launches time out or the File-menu fallback
  fails. Dismiss the dialog and rerun; it is not an app regression.

## What was fixed this session (do not redo)

Browser / preview
- `BrowserPanelView.swift`: `WebViewContainer` syncs the WKWebView frame on
  every `layout()`, re-asserts it on attach, clips to bounds (fixed the
  stale-wide-frame clipping).
- `MainWindowView.swift`: dock widths `340/460/680`; unique toolbar a11y
  identifiers (`browser-toggle`, `simulator-toggle`, `diagnostics-toggle`,
  `bots-toggle`).
- `BrowserController.swift`: `SavedDocumentRegistry` allowlist for
  `save_document` output; workspace-relative path resolution; `loadFileURL`
  read access for local pages; `navigationFailed` error; `lastError` in
  `pageInfo()`.

Agent reliability
- `AgentLoop.swift`: Reliability-V2 interlock gated on `configuration.reliabilityV2`
  (chat-only no longer dies); verification falls back to `run_command` when
  `build_diagnostics` is absent; `looksLikeVerificationCommand` is tokenized
  (no more `mkdir build` paying verification debt).
- `ToolParser.swift`: `<![CDATA[…]]>` values unwrapped; abbreviated names
  aliased (`read`→`read_file`, `run`→`run_command`, …); fenced payload with an
  embedded ``` now still parses.
- `ToolExecutor.swift`: opt-in `treatsErrorPrefixAsFailure` so tools returning
  `"error: …"` count as failures (and never as successful mutations).
- `HookRunner.swift`: stdin written non-blocking with a deadline; SIGPIPE
  ignored (no hang, no crash).
- `PermissionGate.swift`: imported OpenCode `ask` rules actually prompt.
- `CommandPolicy.swift`: quoted/absolute paths unquoted before validation
  (closed `cat "/etc/passwd"` auto-approval bypass).

Providers / inference
- `RemoteProtocol.swift`: per-model OpenCode Zen/Go protocol table (Gemini →
  native Google, Zen paid MiniMax → chat, Go MiniMax/Qwen → messages,
  grok-code → chat, grok-4/grok-build → responses).
- `OpenCodeCompatibility.swift` + `RemoteLLMClient.apply`: headers persist as
  `{env:}`/`{file:}` references, resolved only at request time.
- `RemoteLLMClient.swift`: in-band SSE errors (`error`, `type:"error"`,
  `response.failed`) throw `RemoteLLMError.providerError`; Gemini 3.7+
  `minimal` thinking clamped to `low`.
- `EnginePool.swift`: in-flight activation map (no double load / leaked GGUF).
- `LLMProvider`/`RemoteProtocol`: `sim_swipe` sends argent's `fromX/…` args.

Data / persistence
- `SessionStore.swift`: truncated ciphertext fails closed (no crash);
  per-record supersession stamp stops older retries overwriting newer saves;
  git index path anchored to the workspace (checkpoints no longer clobber the
  wrong repo's index).
- `AppPreferences.swift`: write-then-cache; `write` returns success.
- `TaskQueueStore.swift`: `save` throws; `enqueue` propagates.
- `BotRunStore.swift`: corrupt files quarantined as `.corrupt-<date>`; files
  0600 / directory 0700.
- `MCPClient.swift`: failed stdio handshake disconnects the child.
- `CreateMacAppTool.swift`: refuses to scaffold over `project.yml`/`AGENTS.md`/
  `App` without `overwrite:true`; validates `bundleId`; strips injection chars.

Remote / UI
- `RemoteSessionHost.swift`: `POST /api/sessions` → 409 when a task is running
  (opt-out `"replace": true`).
- `MainWindowView.swift`/`ChatTabStrip.swift`: single history popover (was
  double-bound to `showChatHistory`, breaking ⌘F); delete-active-chat leaves
  the chat + new `sessionDeleted` notification drops its tab; revoke-all
  confirms; tab drag detaches via `openWindow(id:"chat")`; history popover has
  a Close button.
- `iOSApp/RemoteStore.swift`: unhealthy session streams are cancelled so the
  reconnect loop restarts them (no permanent degraded polling).
- `UITests/BeetCodeUITests.swift`: reconciled to the new composer design
  (`textFields["Task description"]`, history via the **Chats** mark) → 13/13
  green, including the restored provider-directory test.

## Remaining backlog

1. Optional, not yet done:
   - Scrub previously resolved literal credential headers out of existing
     `~/Library/Application Support/BeetCode/preferences.json`.
   - `AppPreferencesStore` read-modify-write helpers are unsynchronized;
     `SessionStore` concurrent saves still have no per-id write serialization
     (supersession guard only).
   - `BotRunStore` content is still plaintext (permissions hardened only).
   - Unbounded growth: task capsules, repo summaries, bot run/event history.

## Useful facts

- Key design decisions made: UI tests were updated to the **new** composer
  design (do not restore the old rail/status keys to satisfy tests); remote
  busy returns 409 unless `replace:true`; verification is classified by
  executable/subcommand; OpenCode headers persist as references.
- The `docs/` audits from previous sessions are historical; this file is the
  current source of truth for the queue.
