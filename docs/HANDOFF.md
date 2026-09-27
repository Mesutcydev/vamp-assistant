# Handoff — audit & fix session (2026-09-11)

Continuation notes for a new agent session. This session audited the app
(macOS core + UI + iOS remote), fixed a large batch of verified findings, and
left a specific queue of remaining work. Nothing was committed to git; all
changes are in the working tree.

> 2026-09-12 continuation: backlog items 1–5 below are DONE (see
> "Fixed 2026-09-12"). The remaining queue is at the bottom. All suites green:
> 962 macOS unit / 13 UI / 31 iOS.

## Ground rules & commands

### 2026-09-27: queued follow-up recovery (0.10.46 build 125)

- Reproduced the reported Ready + stranded Queued state: every iOS follow-up
  includes the model selection, and reactivating the current local model
  cancelled the active turn without releasing `activeQueuedTaskID`.
- Reusing an already ready local/API/Codex model is now a no-op. Model
  transitions block queue draining; `stopAndWait` and unexpectedly closed
  streams publish a terminal result. Queue draining can reconcile an obsolete
  active reservation and cancelled drain tasks do not execute later.
- Added authenticated `POST /api/sessions/:id/queue` with `action=send` and
  the existing task ID. Ownership, readiness and running state are checked;
  repeated requests acknowledge the existing run without creating another.
- The iOS queued card has a matching 44-point send arrow and keeps the remove
  control. Queue mutations are serialized, show progress, preserve a failed
  send, and ignore completions from an old Mac connection.
- Verified 1,051 macOS tests passed / 45 opt-in skipped; 41 iOS unit tests
  passed; a real iOS UI-to-HTTP fixture flow sent the queued message exactly
  once from an empty focused composer in light and dark appearances.
  Results: `/tmp/vamp-queue-mac-all2.xcresult`, `/tmp/vamp-queue-ios.xcresult`,
  `/tmp/vamp-queue-ios-dark.xcresult`. Screenshots were visually reviewed.
  Both release targets are version 0.10.46 / build 125.

### 2026-09-27: Huihui vision and simpler iOS session controls

- Fixed `GGUFEngine.Planner.isLoraFile`: full **abliterated** GGUF weights no
  longer match the legacy **abliterate** adapter marker. Regression coverage
  includes the user's exact Huihui Q2_K filename and folders with projectors.
- Installed the publisher's `mmproj-model-bf16.gguf` beside the Huihui Q2_K
  weights in Application Support. SHA-256:
  `c9a09064683620bea3d3bfed5d4462e1a97a7d2fff7e5045d6862a0a85eeb5b5`.
  Source: https://huggingface.co/huihui-ai/Huihui-Qwen3.8-27B-abliterated-GGUF/blob/main/mmproj-model-bf16.gguf
  Live app inference correctly read **BONSAI 42** from a rendered PNG.
  Explicit unload cleared vision state and stopped the llama-server process.
  `LiveGGUFVisionTests` now accepts `BEETCODE_LIVE_GGUF_VISION=1`,
  `BEETCODE_LIVE_VISION_MODEL_ID`, and `BEETCODE_LIVE_VISION_PROJECTOR`
  (forward as `TEST_RUNNER_...` with xcodebuild).
- iOS Model → Local now offers **Unload model** in the existing key style.
  Authenticated `POST /api/models/unload` checks the model identity and rejects
  active chat/local-bot work. Downloads and conversations are preserved.
  Older Mac hosts decode normally and do not show an unsupported control.
- New chat now shows Chat/Code, the message field, one model row, and a
  reachable full-width Start action. Bot/access/provider options are collapsed.
  Valid saved models are reused; unavailable choices fall back to the loaded
  or another available model. Reasoning choices survive model refreshes.
- Validation: macOS 1,048 passed / 45 opt-in skipped; Huihui live vision +
  unload passed separately; iOS 40 unit tests and 3 targeted UI tests passed.
  Light/dark, accessibility, landscape, and keyboard screenshots reviewed.
  New-chat UI test created a session using only a message against an isolated
  loopback fixture host and verified the outgoing model/chat request.
  Both Release builds passed. Artifacts are in `.derived/Build/Products/Release`
  and `.derived-ios/Build/Products/Release-iphoneos`.
- 2026-09-27 release: both platforms are **0.10.45, build 124**. The signed
  Mac Release build replaced `/Applications/Vamp Assistant.app` and launched.
  Its certificate, Team ID, designated requirement, and bundle ID match the
  previous installation. Rollback copy:
  `dist/rollback/Vamp Assistant-0.10.44-build123-before-0.10.45.app`.
  The unsigned IPA and checksum were copied and verified in iCloud Drive's
  `OnDevice Builds` folder. Both artifacts are in `dist/`.
  User authorized publishing the release and updating thevamp.app downloads.
  The release includes the already-present bot reliability changes tested with
  this tree. Temporary UI host and Argent simulator servers were stopped.

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
   - Unbounded growth: task capsules, repo summaries. (Bot history keeps live
     runs plus the newest 100 finished; events are an append-only JSONL log.)

## Useful facts

- Key design decisions made: UI tests were updated to the **new** composer
  design (do not restore the old rail/status keys to satisfy tests); remote
  busy returns 409 unless `replace:true`; verification is classified by
  executable/subcommand; OpenCode headers persist as references.
- The `docs/` audits from previous sessions are historical; this file is the
  current source of truth for the queue.
