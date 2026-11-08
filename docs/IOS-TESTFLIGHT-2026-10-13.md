# Vamp Companion — TestFlight 0.10.54 (134)

Created and uploaded on 13 October 2026 at the user's request. Apple finished
processing the build successfully (`VALID`). The internal beta state is
`READY_FOR_BETA_TESTING`; the external beta state is `READY_FOR_BETA_SUBMISSION`.

## App Store Connect

- Name: **Vamp Companion**
- Primary language: **English (UK)** (`en-GB`)
- App ID: `6822249541`
- Bundle ID: `com.beetcode.remote.ios`
- SKU: `vamp-companion-ios`
- User access: Limited Access; no optional team users added during creation.
- Build/upload ID: `d845403d-e1f5-448d-b427-22dc7bf8d58f`
- [TestFlight](https://appstoreconnect.apple.com/teams/5ddc2a8a-c374-4f06-b9bd-916f198652be/apps/6822249541/testflight/ios)

The iPhone/iPad product name, Home Screen name, Settings product row, VoiceOver
identity and iOS permission descriptions now use Vamp Companion. References to
Vamp Assistant running on the Mac retain the host's name. The bundle identifier
and Keychain service identifier remain `com.beetcode.remote.ios`.

## Build and validation

Built the current workspace with Xcode 27.0 (`27A266a`), scheme
`BeetCodeRemoteIOS`, Release, iPhoneOS, minimum iOS 18.0. The signed archive
and App Store Connect export both succeeded. The IPA contains arm64 code for
iPhone and iPad and passes deep, strict signature verification.

Release signing is scoped to the iOS device target in `project.yml`. The
distribution entitlements are in `scripts/ios-appstore.entitlements`; the
exported app has `get-task-allow=false` and its team-prefixed application and
Keychain identifiers. The App Store profile is `Vamp Companion App Store`,
UUID `7705ba03-fd5b-43a7-95d8-af087e76d816`, team `PUH4GMFV56`.

The iOS icon's unused alpha channel was removed losslessly. Its decoded RGBA
pixels are identical before and after PNG encoding. `PrivacyInfo.xcprivacy`
declares local app preferences (`CA92.1`), elapsed-time calculations (`35F9.1`),
and file size/type metadata in the app sandbox used by the linked terminal
library (`C617.1`). Reason codes were checked against
[Apple's API reason documentation](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype).

- 47 selected iOS regression/render checks passed.
- Three final composer UI checks passed: growth/send, queue/steer/stop, and
  Tools insertion without submission.
- The known pre-existing URLSession invalidation crash in
  `RemoteStoreConcurrencyTests.testOldMacMutationFailuresDoNotAlertOnNewMac`
  was excluded from this run, as in the preceding design validation.
- The original composer source is preserved exactly, SHA-256
  `3eca6b2b36cf68c49d5bc81a4def421925507cabeb453338970378aa6eba169e`.

## Artifacts and upload

Artifacts are saved under `dist/ios-testflight-0.10.54-build-134/`:

- `Vamp Companion.xcarchive`
- `export/Vamp Companion.ipa` (9,265,621 bytes)
- Archive/export logs and provisioning/export metadata
- `verification.json` and `release-receipt.json`
- Apple upload, processed-build and beta-detail responses

IPA SHA-256:
`835b3880d9225356e000d23527d6784295f1bb92b43a62592ca984e0f56ac935`.

The official App Store Connect build upload API received and committed the IPA.
The build is visible on the TestFlight iOS Builds page, and its English (UK)
What to Test notes were verified through the API. The record currently has no
tester groups; no testers were invited and no external beta review was submitted.

Regression results: `/tmp/vamp-companion-testflight-tests.xcresult`.
Composer UI results: `/tmp/vamp-companion-testflight-ui.xcresult`.
