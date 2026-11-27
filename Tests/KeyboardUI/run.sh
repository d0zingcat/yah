#!/usr/bin/env bash
set -euo pipefail

suite=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$suite/../.." && pwd)
install_only=false
if [[ ${1:-} == --install ]]; then
  install_only=true
  shift
fi
if [[ $# -gt 0 && $1 != -* ]]; then
  device=$1
  shift
else
  device=$(xcrun simctl getenv booted SIMULATOR_UDID) || {
    echo 'Boot an iPhone simulator or pass its UDID as the first argument.' >&2
    exit 2
  }
fi
xcrun simctl bootstatus "$device" -b
work=$(mktemp -d "${TMPDIR:-/tmp}/yah-keyboard-ui.XXXXXXXX")
echo "Keyboard UI test files: $work"
destination="platform=iOS Simulator,id=$device"
if [[ -n ${YAH_APP_BUNDLE:-} ]]; then
  app=$YAH_APP_BUNDLE
else
  product_dir=${YAH_BUILD_DIR:-$work/product}
  build_args=(-project "$repo/Yah.xcodeproj" -scheme Yah -configuration Debug
    -destination "$destination" -derivedDataPath "$product_dir")
  if [[ -n ${YAH_PACKAGE_CACHE:-} ]]; then
    build_args+=(-clonedSourcePackagesDirPath "$YAH_PACKAGE_CACHE")
  fi
  xcodebuild "${build_args[@]}" build
  app="$product_dir/Build/Products/Debug-iphonesimulator/Yah.app"
fi
xcrun simctl install "$device" "$app"
if $install_only; then
  echo 'Enable Yah in Settings → General → Keyboard → Keyboards → Add New Keyboard.'
  exit 0
fi
command -v xcodegen >/dev/null || { echo 'Install XcodeGen and add it to PATH.' >&2; exit 2; }
# VoiceUI checks the denied-microphone path after opening the real app.
xcrun simctl privacy "$device" revoke microphone local.yah.ios
cp -R "$suite/Host" "$suite/Tests" "$suite/project.yml" "$work/"
(cd "$work" && xcodegen generate --spec project.yml)
xcodebuild -project "$work/KeyboardUI.xcodeproj" -scheme KeyboardUI \
  -destination "$destination" -derivedDataPath "$work/test-build" \
  -parallel-testing-enabled NO -resultBundlePath "$work/KeyboardUI.xcresult" "$@" test
