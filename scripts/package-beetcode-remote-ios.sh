#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/BeetCode.xcodeproj"
WORK="$ROOT/.packaging-beetcode-remote-ios"
DERIVED="${BEETCODE_IOS_DERIVED_DATA:-$ROOT/.derived}"
STAGING="$WORK/staging"
OUTPUT="$ROOT/dist"
APP="$DERIVED/Build/Products/Release-iphoneos/BeetCode Remote.app"

cd "$ROOT"
mkdir -p "$OUTPUT" "$WORK"
xcodegen generate --spec "$ROOT/project.yml"
xcodebuild -quiet -project "$PROJECT" -scheme BeetCodeRemoteIOS \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= build

[[ -d "$APP" ]] || { echo "Missing built app: $APP" >&2; exit 1; }
VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Info.plist")"
BUILD="$(plutil -extract CFBundleVersion raw "$APP/Info.plist")"
NAME="BeetCode-Remote-iOS-${VERSION}-build-${BUILD}-unsigned.ipa"
IPA="$OUTPUT/$NAME"

find "$STAGING" -depth -delete 2>/dev/null || true
mkdir -p "$STAGING/Payload"
ditto --norsrc --noextattr "$APP" "$STAGING/Payload/BeetCode Remote.app"
rm -f "$IPA" "$IPA.sha256"
(cd "$STAGING" && COPYFILE_DISABLE=1 zip -qryX "$IPA" Payload)
unzip -tq "$IPA" >/dev/null
[[ "$(unzip -Z1 "$IPA" | awk -F/ '$1 == "Payload" && $2 ~ /\\.app$/ { print $2 }' | sort -u | wc -l | tr -d ' ')" == "1" ]]
file "$APP/BeetCode Remote" | grep -q arm64
[[ "$(plutil -extract CFBundleIdentifier raw "$APP/Info.plist")" == "com.beetcode.remote.ios" ]]
[[ ! -e "$APP/embedded.mobileprovision" ]]
[[ ! -d "$APP/_CodeSignature" ]]
(cd "$OUTPUT" && shasum -a 256 "$NAME" > "$NAME.sha256")
echo "$IPA"
echo "Sideload with AltStore, SideStore, Sideloadly, or your own signing workflow."
