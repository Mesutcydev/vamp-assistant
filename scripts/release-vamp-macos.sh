#!/usr/bin/env bash
# Use Xcode's Developer ID distribution flow with its signed-in Apple account.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:---prepare}"
[[ "$MODE" == --prepare || "$MODE" == --submit || "$MODE" == --export-notarized ]] || {
  echo "usage: $0 [--prepare | --submit | --export-notarized /path/to/App.xcarchive]" >&2; exit 1;
}
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if [[ "$MODE" == --export-notarized ]]; then
  ARCHIVE="${2:?Pass the notarized xcarchive path}"
  EXPORT="$(dirname "$ARCHIVE")/notarized"
  xcodebuild -exportNotarizedApp -archivePath "$ARCHIVE" -exportPath "$EXPORT"
  bash "$ROOT/scripts/finalize-vamp-macos.sh" "$EXPORT/Vamp Assistant.app"
  exit
fi

# Exclude revoked/expired certificates. Resolve the identity before building so
# Xcode cannot silently pick an old certificate with the same display name.
IDENTITIES="$(security find-identity -v -p codesigning | awk '/Developer ID Application:/ && !/CSSMERR/ {print}')"
if [[ -n "${VAMP_SIGNING_IDENTITY:-}" ]]; then
  SELECTED="$(printf '%s\n' "$IDENTITIES" | awk -v identity="$VAMP_SIGNING_IDENTITY" 'index($0, identity) {print}')"
else
  SELECTED="$IDENTITIES"
fi
COUNT="$(printf '%s\n' "$SELECTED" | awk 'NF {n++} END {print n+0}')"
[[ "$COUNT" == 1 ]] || {
  echo "Expected one valid Developer ID identity; set VAMP_SIGNING_IDENTITY to its SHA-1 when there are multiple." >&2
  exit 1
}
IDENTITY="$(printf '%s\n' "$SELECTED" | awk '{print $2}')"
TEAM="$(printf '%s\n' "$SELECTED" | sed -E 's/.*\(([A-Z0-9]+)\)".*/\1/')"
[[ "$TEAM" =~ ^[A-Z0-9]{10}$ ]] || { echo "Cannot determine signing Team ID." >&2; exit 1; }

cd "$ROOT"
xcodegen generate
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' App/Info.plist)"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' App/Info.plist)"
WORK="$ROOT/dist/macos-${VERSION}-build-${BUILD}"
[[ ! -e "$WORK" ]] || { echo "Release work already exists: $WORK. Use the exported app with finalize-vamp-macos.sh." >&2; exit 1; }
mkdir -p "$WORK"
DESTINATION=export
[[ "$MODE" != --submit ]] || DESTINATION=upload

cat > "$WORK/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>developer-id</string>
<key>destination</key><string>$DESTINATION</string>
<key>signingStyle</key><string>manual</string>
<key>signingCertificate</key><string>$IDENTITY</string>
<key>teamID</key><string>$TEAM</string>
</dict></plist>
PLIST

xcodebuild -project BeetCode.xcodeproj -scheme BeetCode -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$ROOT/.derived" \
  -archivePath "$WORK/Vamp Assistant.xcarchive" \
  ARCHS=arm64 EXCLUDED_ARCHS=x86_64 CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM" \
  ENABLE_HARDENED_RUNTIME=YES CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  OTHER_CODE_SIGN_FLAGS=--timestamp archive
xcodebuild -exportArchive -archivePath "$WORK/Vamp Assistant.xcarchive" \
  -exportPath "$WORK/export" -exportOptionsPlist "$WORK/ExportOptions.plist" \
  -allowProvisioningUpdates

if [[ "$MODE" == --submit ]]; then
  echo "Submitted through Xcode. Once Apple accepts, run:"
  echo "scripts/release-vamp-macos.sh --export-notarized '$WORK/Vamp Assistant.xcarchive'"
  exit
fi
APP="$WORK/export/Vamp Assistant.app"
codesign --verify --deep --strict "$APP"
echo "Exported Developer ID app: $APP"
echo "Open $WORK/Vamp Assistant.xcarchive in Xcode Organizer."
echo "Choose Distribute App > Direct Distribution (Developer ID) to notarize."
echo "After export, run scripts/finalize-vamp-macos.sh with the notarized app."
