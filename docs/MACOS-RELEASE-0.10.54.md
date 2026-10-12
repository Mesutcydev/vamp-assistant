# Vamp Assistant 0.10.54 (133)

The redesigned macOS workspace uses Chats, Devices, and Settings, optional project tools, persisted docking, and inline specialist work. Dark surfaces use warmer charcoal with softer burgundy. One native sidebar toggle owns window navigation.

## Distribution verification

- The arm64 Release archive and Developer ID upload succeeded with team `PUH4GMFV56`.
- Apple accepted the app. The export and the app extracted from its ZIP passed deep strict signatures, hardened runtime, secure timestamps, absence of debugger entitlement, stapled-ticket validation, and Gatekeeper (`Notarized Developer ID`).
- Sparkle 2.10.0 uses the existing `vamp-assistant` Keychain account and embedded public key. Both new feed and archive signatures verify; the previous 0.10.53 feed item remains available.
- Public archive: `Vamp-Assistant-0.10.54-build-133-public.zip`, 16,482,747 bytes.
- SHA-256: `e713512d85668a1626af9910b4dc7a9cac6f8449847e5da0ebecf7ea400d2f0c`.
- macOS unit checks: 1,134 tests, 51 existing skips, zero failures. Final full UI acceptance remains incomplete due Xcode automation-mode and native accessibility timeouts. iOS downloads are unchanged.

## Publication

[Release v0.10.54](https://github.com/Mesutcydev/vamp-assistant/releases/tag/v0.10.54) provides the ZIP and checksum. The signed feed is published at the existing GitHub Pages URL, and [thevamp.app/assistant](https://thevamp.app/assistant/) provides the current Mac download.

Local artifacts and machine-readable evidence are in `dist/macos-0.10.54-build-133/` and `dist/updates/0.10.54-build-133/`. Existing stored data, paired-client trust, provider credentials, and appearance preferences are preserved.
