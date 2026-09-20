# Vamp Assistant iOS task list

## Release — paused by user; UI reset takes priority

- [x] Fix filename double encoding in shared-file downloads.
- [x] Guard Stop, queue cancellation and checkpoint undo against stale Mac connection completions.
- [x] Add filename/path and connection-race regression coverage: 26 tests passed.
- [x] Verify real-host upload/download with spaces and Unicode after fixes.
- [ ] Build Release for physical iPhone/iPad.
- [ ] Package unsigned IPA with Payload/Vamp Assistant.app and sideload entitlements.
- [ ] Validate archive, device architecture, version, and SHA-256 checksum.
- [ ] Publish the versioned IPA and checksum to the Assistant release.
- [ ] Refresh thevamp.app Assistant download; verify public download bytes.

## Active: hard-reset design migration

Full brief: IOS-HARD-RESET-DESIGN-BRIEF.md. Supersedes the earlier chat-only brief.

- [ ] Refine compact chat top bar and slim status strip.
- [ ] Standardize transcript width, vertical rhythm, user command cards and structured assistant typography.
- [ ] Rebuild reasoning as collapsible technical modules.
- [ ] Refine composer into editor, distinct modular controls and micro-status zones.
- [ ] Strengthen separators, model control containment and anchored Send button.
- [ ] Preserve keyboard ownership, safe areas, touch targets and reduced-motion behavior.
- [ ] Apply consistently to empty/live/long chats, model picker, tools/context and relevant new-session controls.
- [ ] Verify phone portrait/landscape and iPad behavior.
- [ ] Capture portrait, keyboard, long/empty chat, model picker, tools and Light/Dark comparison.

Color: neutral grayscale Dark surfaces; latest brief permits tiny semantic LEDs and orange hardware markers. No green-tinted surfaces.

Release state: build 92 was published before the stop request. Website deployment failed the apps.json freshness check and the public page still links the older build. Do not resume publication during this UI reset.
