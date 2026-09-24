# macOS UI audit — 24 September 2026

## Why the earlier polish missed these issues

The earlier review built the project and checked selected captures, but did not
inspect the installed macOS 27 app across the actual sidebar, Bots, Devices,
and narrow Settings states. A successful build did not prove that AppKit's
toolbar and SwiftUI's split view shared the same layout origin. The native
segmented pickers were also held in frames narrower than their intrinsic width.

## Audit and changes

| Area | Observed problem | Cause | Change |
| --- | --- | --- | --- |
| Chat, Bots, Devices | A grey band between the titlebar and detail canvas covered the Bots and Devices headers. | Removing `.fullSizeContentView` made `NavigationSplitView` apply a second titlebar inset. | Keep the native full-size content style and let the split view own the toolbar safe area. |
| Chat history sidebar | The Conversations selection sat inside the rounded upper-left panel corner, with an empty strip above it. | The first destination used the same inset and rounded pill as inner rows. | Make the first destination meet the sidebar's top and left edges, with a top-left radius matching the panel corner; keep the icon and title on the shared navigation axis. |
| Settings > General | The OLED segment drew beyond the Appearance card. Narrower windows could also crowd Typeface and Text size. | A fixed SwiftUI width did not constrain AppKit's intrinsic segmented width. | Remove fixed widths and use native popup menus for controls that cannot fit in the available horizontal space. |
| Window launch and UI tests | Repeated UI launches sometimes produced two overlapping windows, making controls ambiguous or nonhittable. | The test's two-second New Window fallback raced a slow SwiftUI launch; the app's five-second recovery could do the same. | Wait for the first window, lengthen the app's recovery delay, and require exactly one window in smoke previews. |

## Inspection matrix

- Installed app and rebuilt debug app on macOS 27, including the main chat,
  Bots, Devices, and all six Settings sections.
- Light, dark, and OLED captures; standard, 900-point, and 520-point windows.
- Sidebar destinations, toolbar search and actions, model and provider
  directory, composer bounds and controls, and Settings controls.
- The 520-point Settings capture confirms Appearance remains fully inside its
  card while Typeface and Text size become compact menus.

## Verification

- macOS `BeetCodeTests` on the final source: 1,031 passed, 45 skipped, no
  failures (1,076 total).
- macOS UI suite: 21 of 22 cases passed in the broad run. The remaining case
  timed out while XCUITest synthesized a long text entry. Replacing that entry
  with three short Shift+Return lines verified composer growth and clearing in
  a focused rerun, so all 22 behavior checks passed across the two runs.
- The sidebar corner and minimum-width Settings checks both passed. The
  minimum-width Settings screenshot was inspected directly.
- iOS companion `BeetCodeRemoteIOSTests`: 37 passed, no failures.

The audit covers observable macOS interface states and deterministic test
flows. It does not assert that every possible window arrangement, display
scale, accessibility preference, or account state has been exercised.
