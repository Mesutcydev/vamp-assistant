# Vamp Companion iOS task list

## TestFlight — resumed by user on 2026-10-13

The iPhone/iPad client is now Vamp Companion. The user requested an App Store
Connect record and a TestFlight upload after the reference-led design revision
and restoration of the original composer.

- [x] Rename the iOS product, settings, accessibility labels and permission copy.
- [x] Create Vamp Companion, English (UK), SKU `vamp-companion-ios`, with Limited Access.
- [x] Register `com.beetcode.remote.ios` and create its App Store distribution profile.
- [x] Archive and export signed version 0.10.54, build 134, for iPhone and iPad.
- [x] Validate the signature, distribution entitlements, architecture and privacy manifest.
- [x] Verify the icon is opaque with identical decoded pixels.
- [x] Run 47 selected regression/render checks and three composer UI checks.
- [x] Upload build 134 to App Store Connect (app ID `6822249541`).
- [x] Confirm Apple processing (`VALID`, ready for internal beta testing) and save the release receipt.

Release details: [IOS-TESTFLIGHT-2026-10-13.md](IOS-TESTFLIGHT-2026-10-13.md).

## Earlier sideload release — historical pause

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

Historical release state: build 92 was published before the earlier stop request.
Website deployment failed the apps.json freshness check and the public page still
linked the older build. The 2026-10-13 request above resumes App Store Connect and
TestFlight work after the UI revision.
