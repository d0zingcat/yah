#!/bin/bash
# Usage: Tools/install-mac.sh builds and installs YahMac without logging out.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
build_dir=/tmp/yah-mac-build
destination="$HOME/Library/Input Methods/YahMac.app"

xcodebuild -project "$root/Yah.xcodeproj" -scheme YahMac -configuration Debug \
    -derivedDataPath "$build_dir" build

identity="$(security find-identity -v -p codesigning | awk '/"Apple Development/ && !/CSSMERR/ {print $2; exit}')"
identity="${identity:--}"
codesign --force --deep --sign "$identity" "$build_dir/Build/Products/Debug/YahMac.app"

while IFS= read -r pid; do
    kill "$pid"
done < <(ps -axo pid=,command= | awk -v executable="$destination/Contents/MacOS/YahMac" '
    {
        pid = $1
        sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "")
        if ($0 == executable || index($0, executable " ") == 1) print pid
    }
')

mkdir -p "$(dirname "$destination")"
rm -rf "$destination"
ditto "$build_dir/Build/Products/Debug/YahMac.app" "$destination"
"$destination/Contents/MacOS/YahMac" --install
