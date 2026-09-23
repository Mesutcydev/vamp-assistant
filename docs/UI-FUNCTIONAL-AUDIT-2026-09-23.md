# Vamp Assistant UI and functional audit — 23 September 2026

## Scope and findings

Reviewed the macOS window chrome, sidebar, shared cards, composer, toolbar search, and Bots editor; reviewed the iOS conversation recovery path and composer activity state. The principal issues found were:

1. The macOS window used opaque sidebar and toolbar planes and an opaque writing well. The shared card material had little visible depth in dark mode and did not provide a solid fallback for Reduced Transparency.
2. Command–F could focus a toolbar search field immediately before revealing the sidebar. The layout change could replace that field, leaving subsequent typing outside search. A baseline UI test reproduced this.
3. A toolbar update observer wrote two diagnostic probe files synchronously on every window update. This work was unnecessary during normal interaction.
4. The iOS conversation Retry spinner cleared after one scheduler yield even when loading was still underway. A healthy background poll could also clear the global error for a failed conversation load and leave the screen displaying an indefinite opening state. Deleting the selected conversation on the Mac had the same visible result.
5. The Bots UI test still expected a page-filling editor after the product moved to a bounded task editor. Its width assertion failed on the current UI.
6. The iOS composer's accessibility identifier was attached to the decorated container, so both static text and the real text field inherited it. UI automation selected static text during rotation even while the text field retained keyboard focus.
7. The iOS intrinsic-sizing test still asserted the older 90–100pt composer after a 20pt status rail was added. The current surface is 126pt at the tested widths, and the old assertion failed without an app layout failure.
8. The Sessions shortcut clipped its disconnected status in a narrow three-column action bank.

## Changes

- The macOS composer uses native Liquid Glass on macOS 26 and later, a frosted material on older supported macOS, and a solid surface under Reduced Transparency or Increased Contrast. Shared cards and the sidebar have a restrained frosted tint and edge treatment. The sidebar footer now shares the continuous sidebar material, and the toolbar uses a material background.
- Command–F reveals the conversation sidebar first, then focuses the current toolbar search field. The synchronous toolbar probes and the stale field observer were removed.
- The iOS Retry indicator remains active until the async load ends. Conversation-load failures and deletion have a dedicated inline error that a background refresh cannot erase. The activity light now responds when active state changes.
- The iOS composer identifier and label are now attached to the native text field; its UI test addresses that field directly.
- The Bots UI assertion now checks the intended bounded editor and retains its navigation checks.
- The iOS sizing assertion now bounds the complete composer at 120–130pt while retaining checks for short-draft stability, six-line growth, overflow capping, and compact-height sizing.
- The Sessions shortcut uses the shorter “Reconnect” action label when offline; its full connection detail remains available above the shortcuts.

## Verification

- macOS Debug build: passed with Xcode 27 beta.
- macOS unit suite: **1,075 executed, 45 skipped, 0 failed**. Result bundle: `/tmp/vamp-mac-unit-audit.xcresult`.
- Focused macOS UI suite: **3 passed, 0 failed** (Command–F, Bots layout/navigation, eight-screen light/dark capture matrix). Result bundle: `/tmp/vamp-mac-glass-ui-2.xcresult`.
- Focused iOS remote-store suite: **14 passed, 0 failed**, including new failed-load and removed-conversation recovery cases. Result bundle: `.derived-ios/Logs/Test/Test-BeetCodeRemoteIOS-2026.09.23_23-00-46-+0300.xcresult`.
- Complete iOS remote unit target after the Sessions caption change: **36 passed, 0 failed**, including intrinsic sizing, draft persistence, and rendered component checks. The finalized result bundle is `/tmp/vamp-ios-postcleanup.xcresult`.
- iOS composer UI suite: **5 passed, 0 failed**, including offline drafting through rotation, Send/Queue/Steer/Stop, sizing, and disabled submission. Result bundle: `/tmp/vamp-ios-composer-ui-2.xcresult`.
- `git diff --check`: clean.

The initial full macOS run was interrupted after its UI runner stopped progressing. Its result bundle recorded 1,031 passed tests, 45 skipped, and four failures (two UI assertions addressed above, one timed-out synthetic UI event, and one cancellation). It is not counted as a passing full suite. The focused post-change suite passed.

A separate QA iPhone simulator run reported draft-save failures, and a later Xcode run could not finalize its result bundle while the data volume had about 300 MB free. I removed the extra derived-data directory created for this audit, recovered about 900 MB, and repeated the complete iOS suite successfully on the iPhone 17 simulator. No production draft-store code was changed based on the storage-constrained run.

Visual review used the final [dark chat](../../tmp/vamp-audit-2026-09-23/33336A08-B711-4BFC-B2B5-375DBB39914A.png), [light chat](../../tmp/vamp-audit-2026-09-23/92ED1E80-D839-48BD-AE14-CA4CC90FD5E4.png), and [dark model library](../../tmp/vamp-audit-2026-09-23/570A934A-AB8E-4F5D-BBC1-5D46794F3ECF.png) captures. The dark Bots attachment caught a transient system menu over the app, so it was not used for visual judgment.

The iOS check used the production composer fixture's [light empty state](../../tmp/vamp-audit-2026-09-23-ios/4001F803-0940-414C-AB61-D068DD6FC177.png) and [dark running state](../../tmp/vamp-audit-2026-09-23-ios/3371F604-21EC-421F-9B35-25990574E0B0.png).
The remote-screen capture matrix was also reviewed for pairing, Sessions, chat, Bots, models, approvals, and Settings across the available light/dark states. Its captured [manifest](../../tmp/vamp-audit-2026-09-23-ios-matrix/manifest.json) maps each screen state to an image.

## Remaining validation

- Re-run the full macOS suite when desktop UI automation is free of unrelated foreground-window interruptions, especially the long-draft composer event that timed out in the initial run.
- Validate live iPhone-to-Mac pairing, streaming, approvals, and VoiceOver on devices. The deterministic remote-store tests do not exercise those round trips.
