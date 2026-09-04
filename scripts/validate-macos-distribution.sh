#!/usr/bin/env bash
# Read-only gate for public Developer ID distribution. Run before packaging.
set -euo pipefail
APP="${1:?usage: validate-macos-distribution.sh /path/to/App.app}"
[[ -d "$APP" ]] || { echo "Missing app: $APP" >&2; exit 1; }
codesign --verify --deep --strict --verbose=2 "$APP"
SIGNATURE="$(codesign -dvv "$APP" 2>&1)"
[[ "$SIGNATURE" == *"Authority=Developer ID Application:"* ]] || {
  echo "Public distribution requires a Developer ID Application signature." >&2; exit 1;
}
[[ "$SIGNATURE" == *"runtime"* ]] || { echo "Hardened runtime is missing." >&2; exit 1; }
ENTITLEMENTS="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null)"
if [[ -n "$ENTITLEMENTS" ]] && [[ "$(printf '%s' "$ENTITLEMENTS" | plutil -extract com.apple.security.get-task-allow raw -o - - 2>/dev/null || true)" == "true" ]]; then
  echo "Public distribution cannot allow debugger attachment." >&2; exit 1
fi
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"
echo "Developer ID, hardened runtime, notarization ticket, and Gatekeeper checks passed."
