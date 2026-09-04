#!/usr/bin/env bash
# Wrap the Release Vamp Assistant.app into a UDZO DMG for distribution.
# Does not rebuild — pass the app you just built with xcodebuild -configuration Release.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/.derived/Build/Products/Release/Vamp Assistant.app}"
DIST="${ROOT}/dist"

if [[ ! -d "$APP" ]]; then
  echo "missing app: $APP" >&2
  echo "usage: $0 [/path/to/Vamp Assistant.app]" >&2
  exit 1
fi

# Preview remains the default for the documented development-signed builds.
# Public packaging must pass the trust gate; this script never signs or submits.
CHANNEL="${VAMP_DISTRIBUTION_CHANNEL:-preview}"
case "$CHANNEL" in
  public) bash "$ROOT/scripts/validate-macos-distribution.sh" "$APP" ;;
  preview) ;;
  *) echo "VAMP_DISTRIBUTION_CHANNEL must be preview or public" >&2; exit 1 ;;
esac

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
# Build number in the filename, matching package-beetcode-remote-ios.sh. Without it two
# different builds share one name and silently replace each other in dist/.
NAME="Vamp-Assistant-${VERSION}-build-${BUILD}-${CHANNEL}"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/beetcode-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$DIST" "$STAGE"
ditto "$APP" "$STAGE/Vamp Assistant.app"
ln -s /Applications "$STAGE/Applications"

DMG="${DIST}/${NAME}.dmg"
[[ ! -e "$DMG" ]] || { echo "Artifact already exists: $DMG. Choose a new build number." >&2; exit 1; }
hdiutil create \
  -volname "Vamp Assistant ${VERSION}" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  "$DMG" >/dev/null

shasum -a 256 "$DMG" | awk '{print $1}' > "${DMG}.sha256"
echo "$DMG"
echo "version=${VERSION} build=${BUILD} sha256=$(cat "${DMG}.sha256")"
