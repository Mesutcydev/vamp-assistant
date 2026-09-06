#!/usr/bin/env bash
# Replace the installed Vamp Assistant.app with a freshly built one, without
# losing the permissions macOS has already granted it.
#
# What actually decides whether permissions survive: TCC (Accessibility,
# Screen Recording, Input Monitoring, Automation) keys its grants to the app's
# bundle identifier AND its code signature — specifically the designated
# requirement. Replace the app with a build signed by the same identity and
# the grants carry over; replace it with an ad-hoc or differently-signed build
# and macOS treats it as a different app and asks again. Nothing can be done
# about that from a script: the TCC database is SIP-protected, and editing it
# is neither possible nor wise.
#
# So this script re-signs the incoming build with the identity the installed
# app already uses (or one you name), compares the two designated requirements
# before it copies, and tells you plainly if the grants are going to reset.
#
# usage:
#   scripts/update-local-install.sh                     # build Release, then install
#   scripts/update-local-install.sh path/to/Vamp\ Assistant.app
#   VAMP_SIGN_IDENTITY="Apple Development: you@example.com (TEAMID)" scripts/update-local-install.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALLED="${VAMP_INSTALLED_APP:-/Applications/Vamp Assistant.app}"
SOURCE="${1:-}"

step() { printf '\n\033[1m%s\033[0m\n' "$*"; }

if [[ -z "$SOURCE" ]]; then
  step "Building Release"
  cd "$ROOT"
  command -v xcodegen >/dev/null || { echo "xcodegen is required" >&2; exit 1; }
  xcodegen generate >/dev/null
  xcodebuild -project BeetCode.xcodeproj -scheme BeetCode -configuration Release \
    -derivedDataPath .derived -skipPackagePluginValidation -skipMacroValidation \
    build >/dev/null
  SOURCE="$ROOT/.derived/Build/Products/Release/Vamp Assistant.app"
fi

# Accept a .zip or a .dmg as well as an .app: a CI build arrives as one of
# those, and unpacking it by hand is where the quarantine flag survives.
case "$SOURCE" in
  *.zip)
    step "Unpacking $SOURCE"
    UNPACK="$(mktemp -d "${TMPDIR:-/tmp}/vamp-app.XXXXXX")"
    ditto -x -k "$SOURCE" "$UNPACK"
    SOURCE="$(find "$UNPACK" -maxdepth 2 -name "*.app" -print -quit)"
    ;;
  *.dmg)
    step "Mounting $SOURCE"
    xattr -dr com.apple.quarantine "$SOURCE" 2>/dev/null || true
    MOUNT="$(mktemp -d "${TMPDIR:-/tmp}/vamp-dmg.XXXXXX")"
    hdiutil attach -nobrowse -quiet -mountpoint "$MOUNT" "$SOURCE"
    UNPACK="$(mktemp -d "${TMPDIR:-/tmp}/vamp-app.XXXXXX")"
    ditto "$(find "$MOUNT" -maxdepth 1 -name "*.app" -print -quit)" "$UNPACK/Vamp Assistant.app"
    hdiutil detach -quiet "$MOUNT" || true
    SOURCE="$UNPACK/Vamp Assistant.app"
    ;;
esac

[[ -d "$SOURCE" ]] || { echo "no app at: $SOURCE" >&2; exit 1; }

# Gatekeeper reports an ad-hoc signed app downloaded from the internet as
# "damaged". It is not damaged: it carries com.apple.quarantine and a
# signature no notarisation covers. Clearing the flag here, before signing,
# is what makes the re-signed copy launch.
xattr -dr com.apple.quarantine "$SOURCE" 2>/dev/null || true

# The identity to sign with: what you asked for, else what the installed copy
# already carries, else the first Apple Development certificate in the keychain.
identity_of() {
  codesign -dvv "$1" 2>&1 | awk -F'Authority=' '/Authority=/{print $2; exit}'
}
IDENTITY="${VAMP_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" && -d "$INSTALLED" ]]; then
  IDENTITY="$(identity_of "$INSTALLED" || true)"
fi
if [[ -z "$IDENTITY" || "$IDENTITY" == "(unavailable)" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/{print $2; exit}')"
fi

if [[ -n "$IDENTITY" ]]; then
  step "Signing with: $IDENTITY"
  # The Mac target carries no entitlements file of its own, so the signature
  # preserves whatever the build produced rather than imposing a new set.
  codesign --force --deep --preserve-metadata=entitlements,flags \
    --sign "$IDENTITY" "$SOURCE"
else
  echo "No signing identity found — installing the build as it is." >&2
  echo "Permissions will almost certainly have to be granted again." >&2
fi

# Compare designated requirements: this is the thing TCC actually matches on.
requirement_of() { codesign -d -r- "$1" 2>/dev/null | sed -n 's/^designated => //p'; }
KEEPS_GRANTS=1
if [[ -d "$INSTALLED" ]]; then
  OLD_REQ="$(requirement_of "$INSTALLED")"
  NEW_REQ="$(requirement_of "$SOURCE")"
  if [[ -n "$OLD_REQ" && "$OLD_REQ" == "$NEW_REQ" ]]; then
    step "Signature matches the installed copy — permissions carry over."
  else
    KEEPS_GRANTS=0
    step "Signature differs from the installed copy."
    echo "  installed: ${OLD_REQ:-<unsigned>}"
    echo "  new:       ${NEW_REQ:-<unsigned>}"
    echo "  macOS will treat this as a different app: Accessibility, Screen"
    echo "  Recording and Automation will each ask again on first use."
  fi
fi

step "Quitting Vamp Assistant"
osascript -e 'tell application id "com.beetcode.app" to quit' 2>/dev/null || true
for _ in $(seq 1 20); do
  pgrep -f "Vamp Assistant.app/Contents/MacOS" >/dev/null || break
  sleep 0.5
done
pkill -f "Vamp Assistant.app/Contents/MacOS" 2>/dev/null || true

step "Installing to $INSTALLED"
# In place, same path: a moved app is a new app to Launch Services, and its
# grants go with the old location. Staged beside the target and swapped, so a
# copy that fails half way cannot leave you with no app at all.
STAGED="${INSTALLED%.app}.new.app"
rm -rf "$STAGED"
ditto "$SOURCE" "$STAGED"
xattr -dr com.apple.quarantine "$STAGED" 2>/dev/null || true
if [[ -d "$INSTALLED" ]]; then
  BACKUP="${INSTALLED%.app}.previous.app"
  rm -rf "$BACKUP"
  mv "$INSTALLED" "$BACKUP"
fi
mv "$STAGED" "$INSTALLED"
rm -rf "${INSTALLED%.app}.previous.app"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INSTALLED/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INSTALLED/Contents/Info.plist")"
step "Installed $VERSION build $BUILD"
[[ $KEEPS_GRANTS -eq 1 ]] && echo "Permissions kept." || echo "Re-grant permissions when prompted."

open "$INSTALLED"
