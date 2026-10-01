# Vamp Assistant macOS distribution

The project uses Sparkle 2.10.0 (pinned in `project.yml`) and Xcode's Developer ID
notarization flow. The app supports Apple Silicon and macOS 15 or later.

## App integration

`AppUpdater` owns one `SPUStandardUpdaterController` for the process. It starts
after application launch, observes Sparkle's update availability and preferences,
and skips startup in an app-hosted XCTest process. The app menu and General
settings share that instance. Sparkle manages the update schedule and persistent
preferences. Automatic checks default to daily; automatic installation and
system-profile transmission default to off.

`SUFeedURL` points to the repository's GitHub Pages `appcast.xml`. `SUPublicEDKey`
contains the public key for the Keychain account `vamp-assistant`. Signed feeds
are required, and update signatures are verified before extraction. The private
key is never embedded in the app, committed, or exported by the release scripts.

Existing builds without Sparkle cannot update themselves. Users install the
first Sparkle-enabled release manually, then future releases use the updater.

## Prepare and notarize in Xcode

1. Run the macOS and iOS unit suites and check both Release builds. Forward
   `TEST_RUNNER_DEVELOPER_DIR` for Ship Center tests that invoke Xcode.
2. Run `scripts/release-vamp-macos.sh --prepare`. It resolves a valid Developer ID
   certificate, archives with hardened runtime, secure timestamps, and no debug
   entitlement injection, then exports through Xcode to re-sign embedded Sparkle
   helper processes. Multiple valid certificates require an explicit
   `VAMP_SIGNING_IDENTITY` SHA-1. Development signing settings stay unchanged.
3. Open the resulting `dist/macos-<version>-build-<build>/Vamp Assistant.xcarchive`
   in Xcode Organizer. Choose **Distribute App → Direct Distribution** (Developer
   ID), use the certificate's team, and upload for notarization. This uses the
   account signed into Xcode. If Xcode requests sign-in, complete it there.
4. Wait for Apple's acceptance and export the notarized app from Organizer.
   Alternatively, `--submit` uses `xcodebuild -exportArchive` with
   `method=developer-id` and `destination=upload`; after acceptance use
   `scripts/release-vamp-macos.sh --export-notarized /path/to/App.xcarchive`.
5. Run `scripts/finalize-vamp-macos.sh /path/to/notarized/App.app`.

The finalizer rejects an app unless its deep signature, Developer ID authority,
hardened runtime, debugger entitlement, stapled ticket, and Gatekeeper assessment
pass. It creates an app-only ZIP with `ditto`, extracts it again, and repeats the
trust checks on the extracted app. ZIP containers cannot themselves be stapled;
the app inside carries the ticket. It then generates the signed appcast and
archive signature with Sparkle's tools, checking that the signing account's
public key matches the embedded key first.

Set `VAMP_SPARKLE_BIN` if the tools are outside
`.derived/SourcePackages/artifacts/sparkle/Sparkle/bin`. Set
`VAMP_SPARKLE_ACCOUNT` only when deliberately using a different Keychain account
with the same public key. Keep a secure backup of the key using Sparkle's
documented procedure; release scripts never export it.

## Publish and verify

1. Upload `Vamp-Assistant-<version>-build-<build>-public.zip` and its `.sha256` file
   to GitHub release `v<version>`.
2. Publish `dist/updates/<version>-build-<build>/appcast.xml` to `docs/appcast.xml`
   on the branch used by the existing GitHub Pages workflow. Keep the exact
   signed bytes. Archives must be available before the feed is published.
3. Download the live feed and archive. Verify the feed with Sparkle's
   `sign_update --account vamp-assistant --verify appcast.xml`, compare the
   archive checksum, extract it, and run `validate-macos-distribution.sh`.
4. Launch a previous Sparkle-enabled, notarized build and use **Check for
   Updates…**. Verify download, installation, relaunch, and the new version. This
   end-to-end check needs two actual releases; compilation alone does not prove
   update installation.

The finalizer preserves prior items by reusing `docs/appcast.xml`, disables delta
generation initially, and leaves its new feed staged. It does not publish,
overwrite an existing ZIP, replace the installed app, or alter user data.
The existing DMG packager can additionally wrap the notarized app with
`VAMP_DISTRIBUTION_CHANNEL=public`; the app's ticket is checked before packaging.

If notarization is pending, retain the `.xcarchive` and resume in Organizer.
If rejected, inspect Xcode's notarization log and fix the specified signing or
runtime issue before building a new archive. Do not publish rejected artifacts.
Changing Developer ID teams from an older preview can cause macOS to request
Keychain or privacy permissions again; retain the existing installed app until
the new release is verified.

References: [Sparkle setup](https://sparkle-project.org/documentation/),
[Sparkle programmatic setup](https://sparkle-project.org/documentation/programmatic-setup/),
[Apple distribution signing](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/).
