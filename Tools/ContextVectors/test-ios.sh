#!/bin/bash
set -euo pipefail
if [[ $# -lt 2 || $# -gt 3 ]]; then
    echo "Usage: $0 BOOTED_SIMULATOR_UDID SOURCE_PACKAGES_DIR [CASES_TSV]" >&2
    exit 2
fi
sim=$1
packages=$2
tools_dir=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$tools_dir/../.." && pwd)
cases=${3:-"$tools_dir/Tests/cases.tsv"}
work=$(mktemp -d "${TMPDIR:-/tmp}/yah-context-check.XXXXXXXX")
bundle_id=local.yah.qa.context-$(uuidgen)
bundle=$work/ContextCheck.app
cleanup() {
    xcrun simctl uninstall "$sim" "$bundle_id" >/dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT
mkdir -p "$bundle"
cp -R "$repo/Shared/RimeData" "$repo/Keyboard/ContextModel" "$bundle/"
cp "$cases" "$bundle/cases.tsv"
cat > "$bundle/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$bundle_id</string>
<key>CFBundleName</key><string>ContextCheck</string>
<key>CFBundleExecutable</key><string>ContextCheck</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1</string>
<key>MinimumOSVersion</key><string>16.0</string>
<key>LSRequiresIPhoneOS</key><true/>
</dict></plist>
PLIST
sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
rime=$packages/artifacts/librime-xcframework/RimeStatic/librime-static.xcframework/ios-arm64_x86_64-simulator
xcrun --sdk iphonesimulator swiftc -parse-as-library -O \
    -target "$(uname -m)-apple-ios16.0-simulator" -sdk "$sdk" \
    -I "$packages/checkouts/librime-xcframework/Sources/RimeHeaders/include" \
    "$repo/Shared/CommunitySchemes.swift" "$repo/Shared/RimeSession.swift" \
    "$repo/Shared/Composition.swift" "$repo/Keyboard/ContextualRanking.swift" \
    "$tools_dir/Tests/ContextCheck.swift" "$rime/librime.a" -lc++ -o "$bundle/ContextCheck"
codesign --force --sign - "$bundle"
xcrun simctl install "$sim" "$bundle"
xcrun simctl launch "$sim" "$bundle_id" >/dev/null
container=$(xcrun simctl get_app_container "$sim" "$bundle_id" data)
report=$container/Documents/result.txt
for ((i=0; i<120; i++)); do
    if [[ -f "$report" ]]; then
        cat "$report"
        echo
        [[ $(tail -1 "$report") == PASS ]]
        exit
    fi
    sleep 1
done
echo "Timed out waiting for the isolated test app" >&2
exit 1
