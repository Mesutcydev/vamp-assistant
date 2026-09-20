# Functional release audit — 2026-09-08

## Implementation follow-up

The subsequent fix request has been implemented locally:

- AppState forwards bot coordinator and computer-manager publications.
- UI answer, steering, and approval actions await runtime acceptance. Persistence and runtime rejection retain input and display errors; concurrent command delivery is guarded.
- Run dispatch waits for durable snapshot persistence. Failed storage pauses new runs, exposes an error, and supports explicit retry. A failed-write/retry regression verifies no runtime starts before storage succeeds.
- Bot task, answer, steering, and team drafts are stored independently of navigation in an owner-only local file. Preview/test hosts use memory-only storage unless an explicit test URL is supplied.
- Interrupted and recoverable runs both expose Resume.
- Sidebar toolbar button uses the native enclosure once, removing the nested dark face.

Verification: **888 Mac tests executed, 9 opt-in skips, zero failures** (879 passed), including four new regression tests. Log: `/tmp/vamp-release-fixes-all-tests.log`. Focused bot suite: 19 tests, zero failures. Fresh optimized Release build passed (`/tmp/vamp-fixed-release-build.log`). No screenshots or installed-app changes.

Publication remains on hold: remote `main` has newer functional code than this checkout, so the source candidate must be reconciled or explicitly selected; available Developer ID certificates are revoked (development-signed preview remains a separate channel). The website draft is in `/tmp/vamp-site-release-20260908`, with 8 release-selection tests and all local page-link checks passing. Live links and previews have not been changed. New public previews must exclude private history.

The findings below preserve the original audit evidence and are not a claim that the local fixes are absent.

## Verdict

**Hold release.** UI is accepted; this audit does not propose another redesign. Automated tests pass, but source review identifies functional gaps in Bots and the available build is not a public-distribution artifact.

Scope: current dirty macOS checkout based on `f8164eb`, version 0.10.29 (85). No production code, permissions, installed application, or user data changed. No screenshots or screenshot-producing UI tests run. Findings below are source-confirmed failure paths, not claims of live end-to-end reproduction.

## Findings, in fix order

1. **P1 — Bots does not reliably observe live state.** `BotDashboardView.swift:23` observes AppState and the main session controller, but reads nested `botRuns` and `botComputers` objects. These are separate ObservableObjects; AppState forwards download/model/account changes, but not these two publishers (`AppState.swift:353`). Background specialist updates therefore do not themselves invalidate the screen. Progress, approval/input controls and computer readiness can remain stale until unrelated state changes. Directly observe the coordinators or forward their changes; test transitions without clicking or typing to refresh.

2. **P1 — Bot command delivery can fail silently after apparent acceptance.** `BotRunCoordinator.swift:184` and `:201` return true before asynchronous command persistence and runtime delivery. A failed enqueue returns silently. The answer UI clears text on that immediate true (`BotDashboardView.swift:259`); approval actions ignore the return value. Steering has the same enqueue-first failure path. Preserve input until acknowledgement, surface persistence/rejection errors, and test an unwritable command store plus a rejecting runtime. Never bypass approval as recovery.

3. **P1 — Durable bot recovery is not guaranteed on save failure.** `BotRunCoordinator.swift:554` swallows snapshot-save errors with `try?`. Runs can appear accepted and execute without durable state, leaving no reliable recovery after a crash. Propagate save failures, retain retryable state, and verify restart after failed writes. Particularly relevant with approximately 1 GiB free on this device.

4. **P2 — Back to chat discards unsent bot drafts.** Individual specialist drafts are local @State (`BotDashboardView.swift:230`); the entire dashboard is removed when returning to chat (`MainWindowView.swift:658`). Specialist switching preserves drafts only while Bots remains mounted. Store drafts outside the conditional view, scoped by specialist, and test leave/reopen and relaunch. Team-task text has the same lifetime issue.

5. **P2 — Interrupted runs have no Resume action in Bots.** The coordinator accepts interrupted runs in `resume(runID:)`, but `BotRunState.isTerminal` includes interrupted. The dashboard takes its terminal branch before the recoverable branch (`BotDashboardView.swift:241`), showing a new-task composer rather than resume. Expose the existing recovery operation for interrupted runs and test both interrupted and recoverable states.

## Release artifact gates

- Latest Debug bundle passes deep/strict signature verification, but the repository's public-distribution validator rejects it: Apple Development signature, not Developer ID Application. Debugger entitlement `com.apple.security.get-task-allow=true` is also present. This is a development/preview artifact, not a notarized public release candidate.
- Installed and latest Debug app both advertise build 85 but have different executable-library SHA-256 values. Installed: `21210691653525d35edeb5656702612d9d14a427dfa24164a8c064bbe2cc53b8`; latest: `cc9997422586b7902b7e4d00ec8bb5d58600619b578f9bd48f3b292e3e12a3b9`. Pick a unique release version/build and tie the tested artifact to an exact source snapshot before packaging or installation.
- Current source has extensive tracked changes and untracked production files. A release built from HEAD alone would not reproduce the tested working tree. Preserve and review all intended files before creating the release snapshot.

## Verification

- Current macOS unit suite: **884 executed, 9 skipped, 0 failures** (875 passed), 77.55 seconds. Includes agent, composer, persistence, remote API, bot store/scheduling and permission/tool tests. This supersedes historical test counts in older reports.
- Debug build passed during the preceding implementation pass.
- Fresh optimized macOS Release build: **passed**, using `.derived-release`; current source compiled successfully with Xcode 27 beta. Build success alone does not establish public-distribution trust or real-device functionality.
- Whole-worktree `git diff --check`: passed.
- Packaging and distribution-validator shell syntax: passed.
- Deep/strict Debug bundle signature: passed. Public signing gate: failed as expected for this development build.
- Fresh Release artifact is arm64 and also passes deep/strict signature verification, but fails the public-distribution gate: it too uses Apple Development signing and retains `get-task-allow=true`. A Release configuration name does not make this a publicly trusted package.

Evidence logs: `/tmp/vamp-functional-release-audit-tests.log`, `/tmp/vamp-functional-release-build.log`.

## Not certified by this audit

- Real local inference and paid/BYOK provider calls: opt-in live tests remained skipped.
- Real bot container startup, streamed bot UI updates, approval/answer delivery, shell/files, restart recovery and permission-denial recovery: require end-to-end acceptance after the fixes above.
- Microphone is explicitly unavailable in this build; do not advertise voice input as functioning.
- No new UI/VoiceOver/screenshot tests, notarization, upload, install, permission grants/resets, or public publishing.
- iOS tests were already running in another task; this audit did not interfere with them or claim their result. Current iOS and stable-toolchain CI results remain separate release gates. Local toolchain is Xcode 27 beta.

## Recommended next pass

Fix findings 1–3 first, then draft/recovery behavior. Add focused regression tests for each. Run the full suites and real Mac smoke flows, produce one uniquely versioned Release candidate, verify its distribution channel and signature, and only then update the installed app or publish. Keep the approved UI unchanged.
