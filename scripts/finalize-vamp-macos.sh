#!/usr/bin/env bash
# Package the notarized app exported by Xcode and generate signed Sparkle feeds.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:?usage: finalize-vamp-macos.sh /path/to/notarized/App.app}"
[[ -d "$APP" ]] || { echo "Missing app: $APP" >&2; exit 1; }
APP="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
bash "$ROOT/scripts/validate-macos-distribution.sh" "$APP"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
WORK="$ROOT/dist/updates/${VERSION}-build-${BUILD}"
mkdir -p "$WORK"
BIN="${VAMP_SPARKLE_BIN:-$ROOT/.derived/SourcePackages/artifacts/sparkle/Sparkle/bin}"
[[ -x "$BIN/generate_appcast" && -x "$BIN/generate_keys" && -x "$BIN/sign_update" ]] || { echo "Sparkle tools missing; set VAMP_SPARKLE_BIN." >&2; exit 1; }
ACCOUNT="${VAMP_SPARKLE_ACCOUNT:-vamp-assistant}"
PUBLIC_KEY="$("$BIN/generate_keys" --account "$ACCOUNT" -p)"
EMBEDDED_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist")"
[[ "$PUBLIC_KEY" == "$EMBEDDED_KEY" ]] || { echo "Sparkle signing key does not match the app's SUPublicEDKey." >&2; exit 1; }
ZIP="$ROOT/dist/Vamp-Assistant-${VERSION}-build-${BUILD}-public.zip"
# ZIP contains only the stapled app. ditto preserves the framework symlinks,
# signing resources, and executable permissions required by Sparkle.
if [[ ! -e "$ZIP" ]]; then
  ditto -c -k --keepParent "$APP" "$ZIP"
fi
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/vamp-zip-verify.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
ditto -x -k "$ZIP" "$STAGE"
bash "$ROOT/scripts/validate-macos-distribution.sh" "$STAGE/Vamp Assistant.app"
# Resume feed signing after a Keychain prompt without replacing the archive.
# Existing bytes are reusable only when the entire app matches this export.
diff -rq "$APP" "$STAGE/Vamp Assistant.app" >/dev/null || {
  echo "Existing ZIP contains a different app; choose a new build number." >&2; exit 1;
}
shasum -a 256 "$ZIP" | awk '{print $1}' > "$ZIP.sha256"
ditto "$ZIP" "$WORK/$(basename "$ZIP")"
ditto "$ZIP.sha256" "$WORK/$(basename "$ZIP").sha256"
if [[ -f "$ROOT/docs/appcast.xml" ]]; then
  cp "$ROOT/docs/appcast.xml" "$WORK/appcast.xml"
fi
"$BIN/generate_appcast" --account "$ACCOUNT" --maximum-deltas 0 --maximum-versions 0 \
  --versions "$BUILD" --link https://thevamp.app/assistant/ \
  --download-url-prefix "https://github.com/Mesutcydev/vamp-assistant/releases/download/v${VERSION}/" \
  "$WORK"
"$BIN/sign_update" --account "$ACCOUNT" --verify "$WORK/appcast.xml"
ARCHIVE_SIGNATURE="$(python3 - "$WORK/appcast.xml" "$ZIP" <<'PY'
import pathlib, sys, xml.etree.ElementTree as ET
feed, archive = sys.argv[1], pathlib.Path(sys.argv[2])
enclosures = [e for e in ET.parse(feed).iter('enclosure')
              if e.get('url', '').endswith('/' + archive.name)]
if len(enclosures) != 1 or int(enclosures[0].get('length', '0')) != archive.stat().st_size:
    raise SystemExit('Appcast archive or length mismatch')
print(enclosures[0].attrib['{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature'])
PY
)"
"$BIN/sign_update" --account "$ACCOUNT" --verify "$ZIP" "$ARCHIVE_SIGNATURE"
# Feed stays staged until its referenced release archive has been uploaded.
echo "Verified notarized app archive: $ZIP"
echo "Signed appcast: $WORK/appcast.xml"
echo "Upload ZIP and checksum to release v${VERSION}, then publish appcast.xml to docs/ on GitHub Pages."
