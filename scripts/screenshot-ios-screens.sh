#!/usr/bin/env bash
# Photographs every core screen of the iOS app, light and dark, against
# fixtures — no paired Mac needed.
#
# Runs the same way locally and in CI. Locally it uses whichever simulator
# runtime your Xcode provides: on macOS 27 the simulators live in DeviceHub,
# but `xcrun simctl` is still the scripting surface, so this script drives that
# rather than any one app.
#
#   ./scripts/screenshot-ios-screens.sh [output-directory]
#
# DEVELOPER_DIR pins the toolchain (Xcode-beta is preferred when both are
# installed); SCREENSHOT_DEVICE names the simulator; SKIP_SCREENSHOT_BUILD=1
# reuses an existing build.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/dist/screens}"
DERIVED="${SCREENSHOT_DERIVED_DATA:-$ROOT/.derived-screens}"
DEVICE_NAME="${SCREENSHOT_DEVICE:-iPhone 17}"
BUNDLE=com.beetcode.remote.ios
SCREENS=(sessions conversation new-session settings bots share computers)

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  for candidate in /Applications/Xcode-beta.app /Applications/Xcode.app; do
    if [[ -d "$candidate/Contents/Developer" ]]; then
      export DEVELOPER_DIR="$candidate/Contents/Developer"
      break
    fi
  done
fi
[[ "$(uname -s)" == "Darwin" ]] || { echo "Needs macOS with Xcode; found $(uname -s)." >&2; exit 1; }
command -v xcrun >/dev/null || { echo "xcrun not found." >&2; exit 1; }
xcrun simctl help >/dev/null 2>&1 || {
  echo "xcrun simctl is unavailable in this toolchain (${DEVELOPER_DIR:-default})." >&2
  echo "Point DEVELOPER_DIR at an Xcode that provides it." >&2
  exit 1; }
echo "Toolchain: ${DEVELOPER_DIR:-$(xcode-select -p)}"

cd "$ROOT"
if [[ "${SKIP_SCREENSHOT_BUILD:-}" != "1" ]]; then
  command -v xcodegen >/dev/null || { echo "xcodegen not found. brew install xcodegen" >&2; exit 1; }
  xcodegen generate --spec "$ROOT/project.yml"
  # No -sdk flag: it would force the simulator SDK onto SwiftTerm's host-side
  # plugin generator too, and the build then cannot find it.
  xcodebuild -quiet -project "$ROOT/BeetCode.xcodeproj" -scheme BeetCodeRemoteIOS \
    -configuration Debug \
    -destination "platform=iOS Simulator,name=$DEVICE_NAME" \
    -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
    -skipPackagePluginValidation -skipMacroValidation build
fi

APP="$DERIVED/Build/Products/Debug-iphonesimulator/Vamp Assistant.app"
[[ -d "$APP" ]] || { echo "Missing built app: $APP" >&2; exit 1; }

DEVICE="$(xcrun simctl list devices available -j | python3 -c "
import json, sys
devices = json.load(sys.stdin)['devices']
name = '$DEVICE_NAME'
for runtime in devices.values():
    for device in runtime:
        if device['name'] == name:
            print(device['udid']); raise SystemExit
raise SystemExit('no available simulator named ' + name)
")"
echo "Simulator: $DEVICE_NAME ($DEVICE)"

mkdir -p "$OUT"
xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" -b
xcrun simctl install "$DEVICE" "$APP"

for appearance in light dark; do
  xcrun simctl ui "$DEVICE" appearance "$appearance"
  for screen in "${SCREENS[@]}"; do
    xcrun simctl terminate "$DEVICE" "$BUNDLE" >/dev/null 2>&1 || true
    # SIMCTL_CHILD_ is how simctl passes an environment variable into the app;
    # --setenv is accepted on the command line and never reaches the process,
    # which is why the first run photographed the pairing screen fourteen times.
    SIMCTL_CHILD_VAMP_REMOTE_TEST_SCREEN="$screen" \
    SIMCTL_CHILD_VAMP_REMOTE_TEST_APPEARANCE="$appearance" \
      xcrun simctl launch --terminate-running-process "$DEVICE" "$BUNDLE" >/dev/null
    # The first frame is an empty window; give SwiftUI time to lay out and the
    # backdrop image time to decode.
    sleep "${SCREENSHOT_SETTLE_SECONDS:-6}"
    xcrun simctl io "$DEVICE" screenshot "$OUT/$appearance-$screen.png"
  done
done

xcrun simctl shutdown "$DEVICE" >/dev/null 2>&1 || true
ls -la "$OUT"
echo "$OUT"
