# Vamp Assistant 0.10.53 (132) macOS release

Prepared on 2026-10-01 with Xcode 27 beta. The iOS app remains 0.10.52 (131).

## Completed

- Sparkle 2.10.0 integrated into the app menu and General settings, with one
  shared updater, daily automatic checks, manual installation, signed feeds,
  and archive verification before extraction.
- New Ed25519 signing key stored in login Keychain as `vamp-assistant`. Signing
  completed through Keychain. No private key was exported.
- Developer ID archive/export signed by team `PUH4GMFV56`, with hardened runtime,
  secure timestamps, no debugger entitlement, and correctly signed Sparkle
  framework helpers.
- Xcode Organizer **Direct Distribution** upload accepted by Apple. Submission:
  `BE8F228A-37F4-4229-A7BF-AE39A9D118B2`. Organizer showed **Ready to distribute**;
  the app was saved using **Export Notarized App**.
- The exported app and the app extracted from the public ZIP both passed deep
  strict signature verification, stapled-ticket validation, and Gatekeeper with
  `source=Notarized Developer ID`.
- Original feed and ZIP Ed25519 signatures verified with Sparkle's official
  tool. A modified feed was rejected.

## Validation

- macOS suite: 1,121 tests, 51 intentional skips, zero failures with Sparkle.
- iOS companion: 47 tests, zero failures.
- macOS Release archive and Developer ID export: passed.
- iOS device Release build: passed.
- Tensor-store completion counters were updated after resuming callers, causing
  two baseline failures in `testConcurrentReadsAreIndependent`. The counters now
  publish before resumption; 35 tensor-store tests passed in each of five runs.
- Shell syntax, Info.plist validation, and diff hygiene passed.

## Artifacts

- Notarized app: `dist/macos-0.10.53-build-132/Vamp Assistant.app`.
- Archive: `dist/macos-0.10.53-build-132/Vamp Assistant.xcarchive`.
- Public ZIP: `dist/Vamp-Assistant-0.10.53-build-132-public.zip` (16,401,062 bytes).
- SHA-256: `23a970c08f6fabb52508c1af8fb9eb2ac2d79bfcc27b292e8c81df444342f1fa`.
- Signed appcast: `dist/updates/0.10.53-build-132/appcast.xml`.
- Machine-readable checks: `dist/macos-0.10.53-build-132/release-verification.json`.

Source includes the preexisting working-tree changes on top of
`8be3fe9dc299b10341744f26f23c39ba382d4e12`; those changes were preserved in release tag `v0.10.53` at `c5418f3fced931bdd6309c159505372e5d7fe6dd`.
The release scripts and recovery procedure are in [macOS distribution](MACOS-DISTRIBUTION.md).

## Publication

The archive URL in the feed targets GitHub release `v0.10.53`. The ZIP must be
available there before deploying the feed to the existing GitHub Pages site.
The notarized ZIP is published at [GitHub release v0.10.53](https://github.com/Mesutcydev/vamp-assistant/releases/tag/v0.10.53). The signed feed and download links are published from `docs/` through GitHub Pages. Existing preview users need to install
this first Sparkle-enabled build manually. A real update-installation test still
requires a subsequent notarized Sparkle-enabled release.

The signing team differs from the development preview team (`438VSM6P5L`), so
macOS may request Keychain or privacy authorization again. The installed app was
not replaced during this work.
