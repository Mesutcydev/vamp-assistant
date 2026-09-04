# Vamp Assistant release improvement work

User authorized implementation of the audit recommendations step by step on 2026-09-04. Work is in `/Users/m/Downloads/beetcode/BeetCode`; preserve the separate dirty Desktop checkout. No deployment or publication has been requested.

## Baseline

- Source baseline: `5d47d21`, macOS 0.10.25 (78), iOS 0.1.35 (57).
- Installed Mac app differs: 0.10.27 (80); reconcile release provenance before shipping.
- iOS baseline: 10 tests passed.
- Mac baseline: 925 tests, 9 skipped, 7 failing assertions in two tests (Ship Center archive and download pause/resume).
- Use `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` for builds and forward the same path as `TEST_RUNNER_DEVELOPER_DIR` for nested Xcode tests. System `xcode-select` points to Command Line Tools; no global developer-directory change was made.

## Stages

- [x] F1: shared authorization lifecycle for all remote streams; idle cancellation, revocation isolation, and session/control separation tests passed.
- [x] F2–F3: connection and selection generations, cancellation of old refreshes, isolated persistence/HTTP test seams. Three delayed-response tests passed, alongside the original 10 iOS tests.
- [x] Download pause/resume: remember Pause before the file downloader exists and reject stale progress callbacks. Pause/resume and immediate Pause during preparation regressions both passed.
- [x] F4–F5: duplicate-send protection, preserving edits while sending, accepted mutation vs refresh failure. Duplicate submission and accepted-POST/failed-refresh regressions pass. Server idempotency/outbox remain a separate feature.
- [x] F6: observable palette without root identity replacement. Navigation identity is preserved. Protected, atomic per-Mac/per-session draft storage survives relaunch; persistence and isolation tests pass.
- [x] F7: notification payloads and navigation include the originating Mac. Payload round-trip and origin navigation tests pass; pending navigation survives initial view creation.
- [x] Resolve baseline Ship Center archive failure; preserve and forward the selected full Xcode developer directory. Focused archive integration passes. Failures now include actual command diagnostics.
- [x] F8: pin CI to Xcode 26.6 on macOS 26; matrix covers both unit suites and both Release builds, retains xcresult, cancels superseded runs. Workflow is edited locally; hosted execution has not occurred. UI verification remains a local release step.
- [x] F9: add an explicit public-distribution gate for Developer ID signature, hardened runtime, debugger entitlement, stapled notarization, and Gatekeeper. Preview/public filenames are distinct and existing artifacts cannot be overwritten. The installed development-signed app correctly fails this public gate. Actual Developer ID signing/notarization requires eligible credentials; no publication performed.
- [x] UI/UX implementation: explicit access gestures, offline drafts, recovery notices, reduced-motion button feedback, and compact accessibility-size pairing intro. Normal-size pairing visual check passed; follow-up XXL screenshot confirms Scan QR, Tailscale, and manual pairing controls now appear in the initial viewport. Full iPad/VoiceOver/connected-flow QA remains external.
- [x] Code cleanup: split the 3,600-line iOS view file into focused files, consolidate connection reset and mutation handling, inject persistence/transport, update onboarding docs. Further host-route extraction is a follow-up refactor.
- [x] Dependency updates: exact MLX Swift 0.31.6 and SwiftTerm 1.19.0 pins validated by Mac/iOS tests; MLX LM remains 3.31.4.
- [x] New functions for this release: connection diagnostics with redacted export, durable mobile drafts, protocol compatibility checks, and host version/build display. The larger feature roadmap is listed separately below.
- [x] Final automated verification: Mac suite, additional pause regression, iOS suite, both Release builds, artifact architecture/bundle checks, shell syntax, and diff hygiene passed. UI verification is partial as detailed below; this is not a claim of public release readiness.

## Recent checks

- `/tmp/vamp-stream-fix-tests.log`: 3 tests passed.
- `/tmp/vamp-stability-tests.log`: 4 tests passed (3 streams + pause/resume).
- `/tmp/vamp-ios-lifecycle-tests.log`: 13 tests passed.
- `/tmp/vamp-final-ios-recovery-tests.log`: 22 tests passed with SwiftTerm 1.19.0.
- `/tmp/vamp-final-macos-tests-retry.log`: 929 tests, 9 opt-in live tests skipped, zero failures with MLX Swift 0.31.6.
- `/tmp/vamp-preparation-pause-test.log`: one additional immediate-pause regression passed.
- `/tmp/vamp-release-ios-final-accessibility.log`: final iOS device Release build passed, including the accessibility layout adjustment. Artifact is arm64, bundle ID `com.beetcode.remote.ios`.
- `/tmp/vamp-ship-toolchain-tests.log`: Ship Center archive test passed.

The original audit report remains a snapshot of the baseline, not a claim that its findings remain unfixed after this work.

## Implemented product additions

- Connection details screen with Mac version/build, protocol compatibility checking, last successful contact, manual retry, and a deliberately redacted ShareLink report.
- Durable mobile drafts, scoped to both computer and conversation; offline editing, save-failure notice, and background flush.
- Access changes originate only from user gestures. Session hydration does not issue approval or access requests.
- Model download Pause is remembered during preparation; late progress cannot overwrite terminal states. Pause/resume regression now uses an isolated manifest directory.
- iOS views are split by pairing, sessions, bots, start-session, conversation, transcript, composer, sharing, and diagnostics. Shared connection persistence has an injectable test implementation.
- System Readiness no longer mistakes Command Line Tools for full Xcode.

## Upstream references

- [MLX Swift 0.31.6](https://github.com/ml-explore/mlx-swift/releases/tag/0.31.6), exact version and resolved revision updated.
- [SwiftTerm 1.19.0](https://github.com/migueldeicaza/SwiftTerm/releases/tag/v1.19.0), exact version and resolved revision updated.
- [GitHub macOS 26 runner image](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md), Xcode 26.6 / iOS 26.5 selected for CI. Local validation uses Xcode 27 beta; CI execution is still required before release.

## Larger feature roadmap and release limits

These ideas from the audit are not represented as shipped functionality:

- Durable outbox with server-side idempotency, including restart and ambiguous-delivery recovery. Current protection prevents concurrent duplicate taps; a lost POST response still needs checking the conversation before retrying.
- Per-device capability grants and a cross-computer attention inbox. Current pairing is still the existing token model with global Mac Control permission; alerts are local observations rather than background push.
- Automated update discovery. Connection details reports installed host/client versions, not the latest public release.
- Further host-route decomposition, complete iPad/VoiceOver/navigation QA, and end-to-end real Mac Control/screen/audio/terminal verification.
- Hosted Xcode 26.6 CI has not been run from this local task. Local builds use Xcode 27 beta.
- The installed Mac app is a different version from this checkout. A release owner must reconcile source provenance and choose new version/build numbers before packaging.
- Actual Developer ID notarization and distribution remain external release steps. No publishing, upload, push, or installation over the user's Mac app was performed.

## UI evidence

- iPhone 17 standard text: pairing screen readable, no visible overlap or truncation (`/tmp/vamp-ui-audit/pairing-dark.png`).
- Initial accessibility XXL screenshot (`/tmp/vamp-ui-audit/pairing-accessibility-xxl.png`) exposed a hero that hid all pairing controls below the fold. `PairingHero` now replaces decorative spacing/marketing copy with a scalable "Connect to your Mac" heading at accessibility sizes.
- System-light setting alone does not exercise the app's Light theme because the app defaults to explicit Dark. In-app theme switching and connected flows were not visually verified.

## Final validation result

- **Mac tests:** 929 tests, 9 opt-in live/model smoke tests skipped, zero failures. One additional preparation-stage Pause test also passed after the full suite.
- **iOS tests:** 22 tests, zero failures.
- **macOS Release:** passed (`/tmp/vamp-release-macos-build.log`), arm64 app, bundle ID `com.beetcode.app`.
- **iOS device Release:** passed (`/tmp/vamp-release-ios-final-accessibility.log`), arm64 app, bundle ID `com.beetcode.remote.ios`.
- **Other checks:** `git diff --check`, shell syntax for all packaging scripts, dependency lockfile pins, and expected rejection of the installed Apple Development app by the public-distribution gate.
- **Warnings:** updated MLX-generated Metal headers emit C++17-extension warnings in Release; no compiler errors. No source inside dependency checkouts was modified.
- **Artifacts:** `/tmp/vamp-release-audit-derived/Build/Products/Release/Vamp Assistant.app` and `/tmp/vamp-release-audit-ios/Build/Products/Release-iphoneos/Vamp Assistant.app`. These verification builds are unsigned; no public package was produced.

- **Post-fix XXL visual check passed for the main actions:** `/tmp/vamp-ui-audit/pairing-accessibility-xxl-fixed.png` shows QR scanning, Tailscale, and manual connection controls in the initial viewport. The supporting assurance cards now stack vertically at accessibility sizes, and their access description no longer promises approval for every action when Auto/Full Access can be enabled. Simulator was restored to dark/medium; text-size restore command exited successfully.
