# Vamp Assistant macOS and iOS release audit

Audited 2026-09-04. Source: `/Users/m/Downloads/beetcode/BeetCode`, commit `5d47d21`, clean at the start. Repository versions: macOS **0.10.25 (78)** and iOS **0.1.35 (57)**. The installed Mac app inspected through its UI is **0.10.27 (80)**; its appearance observations are not proof of the older checkout's runtime behavior. Another checkout at `/Users/m/Desktop/vamp-assistant` has older version metadata and extensive uncommitted work; it was identified but not modified or treated as the release source. Reconcile the installed binary with its exact source before final sign-off.

**Decision: hold a broad public release until remote-stream revocation and iOS state races are fixed and verified.** The product already has substantial capability; reliability and a predictable first-run experience are more valuable than another large feature in this release.

This is an audit, not an implementation pass. Findings below distinguish source-confirmed defects, release-process gaps, and proposed improvements. No product source or settings were changed. This is not an exhaustive security assessment or App Store compliance certification.

## Review coverage

- [x] Read repository instructions and architecture, comparison, and composer documentation.
- [x] Inspect Mac host authorization, token revocation, media streams, and control permissions.
- [x] Inspect iOS pairing, computer switching, session selection, sending, themes, notifications, and composer behavior.
- [x] Inspect build configurations, packaging scripts, CI, tests, and dependency releases.
- [x] Inspect installed Mac home/settings UI and accessibility output.
- [ ] Complete physical-device pairing, sleep/wake, poor-network, VoiceOver, large-text, and iPad split-view acceptance checks.

## Findings requiring fixes

### F1 — P1: revocation does not terminate existing control streams

Evidence: `App/RemoteSessionHost.swift:347`, `:620`, `:1022`, `:1110`, `:1133`, `:1856`; `App/RemoteAccessView.swift:179`.

`revokeAllClients()` and `/api/revoke` invalidate tokens and the generation/digest state consumed by **session** SSE. Screen, audio, and terminal output instead run detached loops that never consult that state. Their authorization and Mac Control permission checks happen only before the response starts. Turning Mac Control off likewise does not terminate these loops; the toggle's change handler returns immediately when disabled.

Consequence: a previously authorized client with an open stream can continue receiving data after access is revoked or Mac Control is disabled. Screen/audio have separate lock handling; that does not implement token revocation. This is source-confirmed; an adversarial live-client reproduction was not performed on the user's Mac.

Fix: register every long-lived connection with a token digest and capability, cancel the matching connections on revocation/expiry, cancel control connections when permission is disabled, and release held input state. Use a cancellation task/registry so an idle terminal is closed even when it emits no new chunks.

Acceptance: two paired clients streaming; revoke A and verify all A streams close promptly while B continues. Repeat for expiry, disabling Control, and revoke-all. New requests must also fail.

### F2 — P1: switching Macs can publish a previous Mac's refresh into the new connection

Evidence: `iOSApp/RemoteStore.swift:189`, `:207`, `:749`, `:876`.

`refresh()` owns an unstructured `refreshTask`. `activateComputer()` cancels polling and session streaming but neither cancels nor invalidates this task. `connectSaved()` for Mac B can await Mac A's existing refresh, which then writes A's session list and status into B's active state, including `updateActiveComputer(...)`. `workspaces` and `botRuns` also survive activation until later loads replace them.

Fix: maintain a connection generation/identity, capture it before each asynchronous load, and discard results after a switch or disconnect. Cancel and detach old refresh tasks safely; clear all host-specific data together. Apply this rule to models, workspaces, bot runs, and control requests as well.

Acceptance: delay A's responses, switch to B, then complete A. Only B's data and expiry metadata may be visible or persisted. Repeat with failed authentication from A and disconnect during refresh.

### F3 — P1: out-of-order conversation loads can strand navigation

Evidence: `iOSApp/RemoteStore.swift:366`, `:1055`; `iOSApp/RemoteViews.swift:2440` and the conversation `.task(id: sessionID)`.

Selection clears `selectedSession`, then awaits the network without a selection generation check. Open A, then B; if A finishes first, it can repopulate the empty selection. B's `applySessionDetail` then rejects B because a different ID is already selected. Callers ignore that rejection and still change options/start streaming. The B view requires detail.id to match B and can remain at “Opening conversation…”. Task cancellation alone does not ensure a late completed result is discarded.

Fix: separate requested session identity from loaded detail, verify both connection and selection identity after every await, and do not start a stream when applying a snapshot failed.

Acceptance: complete A/B responses in both orders, including switching computers while loading. The latest selection always wins; stale errors do not replace the current screen.

### F4 — P1: sending can erase newly typed text and permit duplicate submissions

Evidence: `iOSApp/RemoteViews.swift:2562`, `:3160`; `iOSApp/RemoteStore.swift:613`.

`send()` snapshots `draft`, starts an asynchronous request, and unconditionally empties the current draft when it succeeds. The composer remains editable and has no submission-in-flight state. A user who starts typing the next message before the first request returns loses that text. Repeated taps can submit the same draft again, particularly for queued follow-ups.

Fix: keep a per-conversation submission state and client request ID. Clear only the exact submitted draft, preserve subsequent edits, disable duplicate submission while pending, and retain/recover text on failure. Add server-side idempotency for ambiguous network retries.

Acceptance: delay an accepted send, type new text, then deliver the response: new text survives. Double-tap sends once. A timeout after server acceptance can be reconciled without running the task twice.

### F5 — P2: successful mutations are reported as failures when refresh fails

Evidence: `iOSApp/RemoteStore.swift:396`, `:407`, `:419`, `:534`.

Bot start/steer/workflow and session creation place the accepted POST and a subsequent refresh in the same `do/catch`. If the POST succeeds but refresh fails, the operation returns false/nil and says it could not start or steer. A retry may repeat an operation that already ran. Session creation already received its session ID but discards that success on refresh failure.

Fix: distinguish accepted, awaiting sync, and rejected. Return/store accepted IDs immediately and show refresh errors as a recoverable sync state. Use the idempotency support from F4 for operations that can have side effects.

Acceptance: accepted POST followed by failed GET preserves success and the created ID; retry refresh does not resend the mutation.

### F6 — P2: appearance changes rebuild the entire iOS navigation tree

Evidence: `iOSApp/BeetCodeRemoteApp.swift:45`; `iOSApp/RemoteViews.swift:2440`.

`AccentSync` writes a global palette during `body` and returns `content.id(palette.rawValue)`. Changing the accent replaces the root subtree, resetting view-owned navigation, drafts, sheets, and task lifecycles. The conversation draft is only local `@State`.

Fix: pass palette values through an observable theme/environment without changing root identity. Store drafts by computer/session so navigation and application interruption also preserve work.

Acceptance: change accent while a draft exists and a session is selected; return to the same conversation with the same draft. No extra connection is started solely because the palette changed.

### F7 — P2: notification navigation does not identify the Mac

Evidence: `iOSApp/RemoteNotificationCenter.swift:64` and `:80`; `iOSApp/RemoteViews.swift:484`.

Notification payloads contain only `sessionID`. The app supports multiple Macs, but the notification handler opens that ID through the currently active connection. After switching from A to B, tapping a notification from A attempts to open A's session on B.

Fix: include computer ID and session ID in notification identity/payload, reconnect the matching saved computer before navigating, and provide a clear recovery state when it was removed. Key notification tracking by both identities.

Acceptance: generate a notification from A, switch to B, tap it, and open A's session on A. Removed/expired connections lead to pairing recovery rather than an indefinite spinner.

### F8 — P2: iOS release behavior has no CI gate

Evidence: `.github/workflows/macos.yml:13`, `project.yml` schemes, `iOSTests/RemoteProtocolRegressionTests.swift`.

CI runs only `BeetCodeTests`; it does not build/test `BeetCodeRemoteIOS`. The iOS suite covers decoding and pure regression helpers but does not exercise delayed HTTP responses, navigation races, reconnection, draft retention, or UI. The Mac workflow also relies on the runner's default Xcode despite the explicit compiler requirements in the README.

Fix: add an iOS simulator job, pin a supported Xcode version, and gate both release builds. Add transport injection/URLProtocol fixtures for F2–F5 and UI tests for pairing recovery, keyboard/send, and navigation. Keep live credentials and model weights out of deterministic CI.

### F9 — P1 for mainstream distribution: Mac packaging does not establish release trust

Evidence: `project.yml:85`, `scripts/package-beetcode-dmg.sh`, README installation section.

The checked-in app target uses Apple Development signing. The DMG script packages any supplied app and hashes it, without checking Developer ID, notarization, or Gatekeeper acceptance. The README explicitly describes a non-notarized build. This may be intentional for a developer preview, but it is a substantial installation barrier for a broad consumer release. The installed newer app's notarization was not assessed.

Fix: add a dedicated distribution signing configuration and a packaging gate that checks signature, notarization/stapling, version, and architecture. Keep the unsigned iOS sideload workflow explicitly separate from any future TestFlight/App Store archive configuration.

Apple documents Developer ID signing and notarization for distribution outside the Mac App Store: [Developer ID](https://developer.apple.com/support/developer-id/).

## UI and UX improvements

The installed Mac app has a recognizable visual identity, a clear primary composer, grouped chat history, and accessible names on many controls. The home screen makes model selection a small composer control despite blocking Send until a model is selected. Make “Choose how to run” the primary empty-state action with local-model and API-provider paths, then return directly to the draft.

The following are proposed design improvements, not measured performance/accessibility failures:

| Priority | Area | Concrete improvement | How to verify |
| --- | --- | --- | --- |
| P2 | iOS offline experience | Keep the editor usable while disconnected; disable sending, explain reconnection, and preserve drafts. It is currently disabled by `!isReachable` in `RemoteComposer`. | Disconnect while composing, edit offline, reconnect without losing text. |
| P2 | Safety controls | Explain Auto versus Full Access beside the controls. Separate option hydration from user intent; `.onChange` handlers currently also perform approval actions. | Opening/restoring a session never counts as a new explicit approval. |
| P2 | Product terminology | Replace “Continue this coding task…” for chat-only sessions; consistently distinguish Assistant, Code, Bots, and Mac Control. | Chat and coding sessions show task-appropriate language. |
| P2 | Accessibility | Audit toolbar names, VoiceOver order, Dynamic Type, keyboard focus, and hit targets in the exact release build. Installed AX output described several different toolbar buttons as “Browser” despite distinct help strings; checkout source already uses distinct labels, so this needs a version-matched reproduction. | Each control announces its actual action; no clipping at large text. |
| P2 | Readability | Offer a quieter background behind conversation content; test secondary text on every palette instead of relying on the settings claim that contrast was checked. | Measured contrast and readable long transcripts in light/dark modes. |
| P2 | iPad | Verify portrait, landscape, split view, hardware keyboard, terminal resizing, and approval cards with long previews. | Controls and approvals remain reachable above the software keyboard. |
| P3 | Progress | Separate “request accepted,” “running,” “waiting for approval,” and “waiting for Mac”; make recovery inline and actionable. | Disconnect and failure paths do not present misleading success/failure. |

Notifications currently originate from foreground session observation; no push-delivery path is evident in the reviewed client. Do not promise background completion alerts until that behavior is implemented and physically verified.

## Code cleaning

1. Split `RemoteViews.swift` (3,662 lines) into pairing, session list, conversation, composer, bot, and sharing files. Extract actual `View` types with narrow inputs; merely moving computed properties does not create observation boundaries.
2. Split `RemoteStore.swift` (1,125 lines) into connection lifecycle, session operations, and host services. Introduce explicit connection/selection identity first so refactoring does not preserve the races.
3. Split `RemoteSessionHost.swift` (2,509 lines) by route family behind shared authorization and stream-lifecycle policy. Avoid duplicated capability checks that diverge between request and stream paths.
4. Replace the manual `RemoteAppearanceKey: EnvironmentKey` with `@Entry` while implementing the observable theme change; iOS 18 is already the deployment floor.
5. Remove redundant branches such as `RemoteComposer.primaryColor`, which returns the same color in all cases. Replace success-shaped `try?` fallbacks where a transport failure is being confused with an empty result.
6. Refresh onboarding documentation. `AGENTS.md` still claims 370 tests; architecture report sections include older feature-gap statements alongside later addenda. Keep one current capability/release checklist and move historical detail to changelogs.

No recommendation to rename every BeetCode internal symbol: bundle IDs, Keychain services, persisted keys, and wire protocol names need migration planning, and cosmetic renaming would create risk without user value.

## Dependency updates

Upstream pages checked during this audit; do not upgrade blindly immediately before release.

| Dependency | Repository | Upstream observed | Recommendation |
| --- | --- | --- | --- |
| MLX Swift | 0.31.4 | 0.31.6 | Evaluate in an isolated update. The 0.31.5 line raises the Swift tools requirement to 6.3; verify both supported Xcodes and real model load/generation. The 0.31.6 notes include an iOS build fix, but this companion does not depend on MLX directly. |
| MLX Swift LM | 3.31.4 | 3.31.4 latest | Keep the stable pin; no newer stable release was visible. |
| SwiftTerm | 1.15.0 | 1.19.0 stable; 1.20.0 marked prerelease | Evaluate 1.19.0 with terminal keyboard/IME, resize, scrollback, and font-change tests. Do not jump to the prerelease by default. |

Sources: [MLX Swift releases](https://github.com/ml-explore/mlx-swift/releases), [MLX Swift LM releases](https://github.com/ml-explore/mlx-swift-lm/releases), [SwiftTerm releases](https://github.com/migueldeicaza/SwiftTerm/releases). This is not a complete transitive dependency vulnerability audit.

## New functions worth adding

These are product proposals, ordered by practical value after the fixes:

1. **Connection diagnostics:** a single page explaining Mac reachability, pairing expiry, protocol version, Control permissions, and recovery actions, with a redacted export.
2. **Durable mobile outbox:** preserve drafts and explicitly queued requests per Mac/session, with accepted IDs and deduplicated retry. Never silently replay destructive work.
3. **Per-device access management:** named paired devices, last seen, scoped chat/control/file permissions, expiry, and immediate revoke backed by F1's stream registry.
4. **Compatibility handshake:** host/client protocol version and feature flags so older hosts hide unsupported settings/actions instead of matching error text for “unknown endpoint”.
5. **Cross-device attention inbox:** aggregate pending questions, approvals, failed tasks, and completions across Macs; add optional background delivery only after defining and testing the transport.
6. **Release/update status:** show the installed Mac/iOS versions, compatibility, release notes, and a verified update path. First eliminate drift between checkout, installed app, and downloadable artifacts.

## Release sequence and acceptance

1. Fix F1, add adversarial stream-lifecycle tests, and verify with two clients.
2. Fix F2–F5 together around explicit request identity and acceptance state; add deterministic delayed-response tests.
3. Fix F6–F7; verify draft/navigation preservation and multi-Mac notification routing.
4. Add the iOS CI gate; test the exact release artifacts and supported compiler/OS combinations.
5. Run physical iPhone/iPad tests: fresh pairing, expired token, Wi-Fi/Tailscale transition, host restart, lock/unlock, keyboard, clipboard/files, approvals, terminal and screen/audio stop/reconnect.
6. Complete signing/distribution verification and align README, release tags, AltStore metadata, versions, and artifact hashes.
7. Take the small UX improvements first; evaluate dependency updates and new functions in separate changes.

Model correctness and performance still require real MLX/GGUF/BYOK smoke runs, memory pressure, long conversations, and cancellation during tool execution. Passing deterministic tests alone is not proof of those behaviors.

## Validation record

**iOS: build and all 10 regression tests passed, zero failures**, using Xcode beta's iOS 27 simulator and the `BeetCodeRemoteIOS` scheme with simulator signing disabled. These are protocol/helper tests, not UI or network-race tests. Log: `/tmp/vamp-release-audit-ios.log`.

Mac unit-test validation is still running. Initial `xcodebuild` failed because the system developer directory selected Command Line Tools. A subsequent sandboxed attempt could not connect to Simulator services. The retry uses the installed Xcode beta and approved external execution with `-only-testing:BeetCodeTests`; log: `/tmp/vamp-release-audit-macos-retry.log`. These setup failures are not product compilation failures.

Argent device discovery returned no devices under its current tool environment, although explicit-Xcode `simctl` listed an available iPhone simulator. No iOS visual acceptance is claimed. The installed Mac UI was inspected without changing preferences or running user tasks.
