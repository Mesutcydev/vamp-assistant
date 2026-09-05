#!/usr/bin/env bash
# Unsigned iPhone/iPad IPA with the sideload layout tools expect:
#   Payload/Vamp Assistant.app/...
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Toolchain. With an Xcode beta installed alongside a release Xcode, the one on
# PATH is whatever `xcode-select` points at, which is usually not the beta — so
# resolve it explicitly and say which one built the artifact. Override with
# DEVELOPER_DIR to pin a specific install.
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  for candidate in /Applications/Xcode-beta.app /Applications/Xcode.app; do
    if [[ -d "$candidate/Contents/Developer" ]]; then
      export DEVELOPER_DIR="$candidate/Contents/Developer"
      break
    fi
  done
fi
[[ "$(uname -s)" == "Darwin" ]] || { echo "This script needs macOS with Xcode; found $(uname -s)." >&2; exit 1; }
command -v xcodebuild >/dev/null || { echo "xcodebuild not found. Install Xcode and run xcode-select --install." >&2; exit 1; }
command -v xcodegen >/dev/null || { echo "xcodegen not found. brew install xcodegen" >&2; exit 1; }
echo "Toolchain: ${DEVELOPER_DIR:-$(xcode-select -p)}"
xcodebuild -version | tr '\n' ' '; echo
xcodebuild -showsdks 2>/dev/null | grep -E 'iphoneos[0-9]' | head -1 || {
  echo "No iphoneos SDK in this toolchain." >&2; exit 1; }
PROJECT="$ROOT/BeetCode.xcodeproj"
WORK="$ROOT/.packaging-beetcode-remote-ios"
DERIVED="${BEETCODE_IOS_DERIVED_DATA:-$ROOT/.derived}"
STAGING="$WORK/staging"
OUTPUT="$ROOT/dist"
APP="$DERIVED/Build/Products/Release-iphoneos/Vamp Assistant.app"
ENTITLEMENTS="$ROOT/iOSApp/BeetCodeRemote.entitlements"

cd "$ROOT"
mkdir -p "$OUTPUT" "$WORK"
if [[ "${SKIP_IOS_BUILD:-}" != "1" ]]; then
  xcodegen generate --spec "$ROOT/project.yml"
  xcodebuild -quiet -project "$PROJECT" -scheme BeetCodeRemoteIOS \
    -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
    -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= \
    -skipMacroValidation build
fi

[[ -d "$APP" ]] || { echo "Missing built app: $APP" >&2; exit 1; }
[[ -f "$ENTITLEMENTS" ]] || { echo "Missing entitlements: $ENTITLEMENTS" >&2; exit 1; }
VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Info.plist")"
BUILD="$(plutil -extract CFBundleVersion raw "$APP/Info.plist")"
NAME="Vamp-Assistant-iOS-${VERSION}-build-${BUILD}-unsigned.ipa"
IPA="$OUTPUT/$NAME"
[[ ! -e "$IPA" ]] || { echo "Artifact already exists: $IPA. Choose a new build number." >&2; exit 1; }

find "$STAGING" -depth -delete 2>/dev/null || true
mkdir -p "$STAGING/Payload"
ditto --norsrc --noextattr "$APP" "$STAGING/Payload/Vamp Assistant.app"
# Sideload tools look for a .entitlements file; Xcode archives also ship .xcent.
cp "$ENTITLEMENTS" "$STAGING/Payload/Vamp Assistant.app/BeetCode Remote.entitlements"
cp "$ENTITLEMENTS" "$STAGING/Payload/Vamp Assistant.app/archived-expanded-entitlements.xcent"
find "$STAGING" -name '.DS_Store' -delete
rm -f "$IPA" "$IPA.sha256"
(cd "$STAGING" && COPYFILE_DISABLE=1 zip -qryX "$IPA" Payload)
unzip -tq "$IPA" >/dev/null
python3 - "$IPA" <<'PY'
import sys, zipfile
path = sys.argv[1]
with zipfile.ZipFile(path) as zf:
    names = zf.namelist()
apps = sorted({n.split("/")[1] for n in names if n.startswith("Payload/") and n.count("/") >= 1 and n.split("/")[1].endswith(".app")})
top = sorted({n.split("/")[0] for n in names if n.split("/")[0]})
if top != ["Payload"]:
    raise SystemExit(f"IPA top-level must be Payload/, got {top}")
if apps != ["Vamp Assistant.app"]:
    raise SystemExit(f"expected one Payload app, got {apps}")
required = {
    "Payload/Vamp Assistant.app/BeetCode Remote.entitlements",
    "Payload/Vamp Assistant.app/archived-expanded-entitlements.xcent",
    "Payload/Vamp Assistant.app/Info.plist",
}
missing = sorted(required - set(names))
if missing:
    raise SystemExit(f"IPA missing {missing}")
print("ipa-structure=Payload/Vamp Assistant.app + .entitlements")
PY
file "$APP/Vamp Assistant" | grep -q arm64
[[ "$(plutil -extract CFBundleIdentifier raw "$APP/Info.plist")" == "com.beetcode.remote.ios" ]]
[[ ! -e "$APP/embedded.mobileprovision" ]]
[[ ! -d "$APP/_CodeSignature" ]]
(cd "$OUTPUT" && shasum -a 256 "$NAME" > "$NAME.sha256")
echo "$IPA"
echo "Sideload with AltStore, SideStore, Sideloadly, or your own signing workflow."
