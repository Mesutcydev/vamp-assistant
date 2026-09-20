# macOS UI and UX polish — 12 September 2026

## Implemented

- **Conversation:** user bubbles, trailing alignment and 72% width constraints removed. Both speakers use the reading column, clear You/Vamp labels and 24pt turn spacing. User typography now matches the answer's body size. Selection, Markdown, copy actions and answer metrics remain.
- **Composer:** dock follows the 800pt reading column instead of stretching across the window. Native text starts on one line, grows to six, and retains keyboard submission preferences and marked-text handling. Existing model, mode, tools, project, history, attachment and send/stop actions remain.
- **Action density:** removed duplicate search, browser and folder actions from the composer; search remains in Chats and Command–F, browser in Tools and the toolbar, and folder selection in Project. Removed the permanently disabled voice placeholder.
- **Interaction:** quiet toolbar buttons gain visible hover and touch-down shading without scaling the label. Selected destinations expose their selected accessibility state. Disabled custom menu options now use native disabled semantics.
- **Hardware:** existing keycap construction retained. Travel reduced to 1pt, disabled under Reduce Motion; 80ms depression and 140ms release. Increased Contrast strengthens the rim.
- **Reading surface:** off-white light canvas and near-black dark canvas. Controls retain silver/graphite materials and the user's accent choice.
- **Settings and navigation:** readable section titles replace tiny engraved headings. Decorative key backgrounds removed from sidebar group icons, reducing false button affordances. Welcome copy is a readable prompt instead of a tiny uppercase slogan.

- **Window recovery:** searches nested menus for New Window, ignores hidden utility windows when deciding whether a main window exists, and retries when the application becomes active. The nested-menu lookup has regression coverage.

## Evidence and checks

- Baseline: 962 macOS tests, 10 skipped, zero failures.
- Implementation regression run: 964 tests, 10 skipped, zero failures, including native light/dark chat and composer rendering.
- Native component previews: [light](../../tmp/macos-polish/native-final/mac-native-chat-light.png), [dark](../../tmp/macos-polish/native-final/mac-native-chat-dark.png). These render the real SwiftUI views in an AppKit host, not a raster approximation. They exclude application toolbar/window chrome.
- Source-before backups: `/Users/m/Downloads/beetcode/tmp/macos-polish/source-before/`.
- Added UI acceptance coverage for intrinsic composer growth, deletion shrinkage and a light/dark full-window capture matrix.

Full-window verification initially failed because this Mac had stale app registrations and occasionally launched without a visible main window. Isolated app identifiers, explicit registration and the window-recovery correction allowed all **15 desktop UI tests to pass**. Four baseline light-mode screenshots were recovered in `before/`; the baseline dark-mode sequence was incomplete. Eight updated light/dark full-window captures are in `after/`. The final Release build also passed (`/tmp/vamp-mac-polish-release-final.log`).

The exact Release build passed all three targeted sizing/capture tests. Its eight final light/dark screenshots are in `after-release/`, including the final 800pt column. No incomplete baseline run is counted as a pass.

The final regression run includes the welcome copy, user-font adjustment, selected-toolbar accessibility trait and window-recovery fix. The final Release gate also covers the reading-column width adjustment. Live model streaming, physical keyboard traversal, full VoiceOver narration and provider/network actions have not been revalidated manually in this pass. Backend APIs, persistence and installed applications were not modified. Existing uncommitted work was preserved.


## Final screenshots

- [Release chat — light](../../tmp/macos-polish/after-release/mac-chat-light.png)
- [Release chat — dark](../../tmp/macos-polish/after-release/mac-chat-dark.png)
- [Settings — dark](../../tmp/macos-polish/after-release/mac-settings-general-dark.png)
- [Models — light](../../tmp/macos-polish/after-release/mac-settings-models-light.png)
- [Bots — dark](../../tmp/macos-polish/after-release/mac-bots-dark.png)

The chat fixture follows the latest item, so its full-window screenshot shows the functional approval panel. The native component previews above show the bubble-free user and assistant messages. Test bundles: `/tmp/vamp-mac-polish-final.xcresult`, `/tmp/vamp-mac-polish-ui.xcresult`, `/tmp/vamp-mac-release-ui.xcresult`. Implementation diff whitespace check passed. The Release artifact is `.derived/Build/Products/Release/Vamp Assistant.app`; it was not installed over the user's application.


## OLED Black appearance

Added **Settings → General → Appearance → OLED Black** alongside System, Light and Dark. The mode persists through the existing appearance preference. It forces dark native controls and uses #000000 for the workspace, reading canvas, navigation, header and silver chassis surfaces. Inset controls retain subtle dark-gray separation and existing accessible foreground colors. Regular Dark remains graphite.

Appearance-dependent surfaces now read observable theme state and create fresh color providers. This fixes the cached-color problem when switching directly between Dark and OLED without recreating the screen or draft. Seven appearance tests cover persistence, native color-scheme mapping, true-black color values, restoration to Dark and surface invalidation. The live UI switch test passed, and its [verified screenshot](../../tmp/macos-polish/oled-live/settings.png) shows the result. The earlier `oled/` screenshot documents the rejected stale-color rendering and is not delivery evidence.

Validation bundles: `/tmp/vamp-oled-refresh-final.xcresult` and `/tmp/vamp-oled-live.xcresult`.

OLED Release build passed (`/tmp/vamp-oled-release-final.log`). Pixel sampling of the live screenshot verified both canvas and title bar as RGB (0, 0, 0).
