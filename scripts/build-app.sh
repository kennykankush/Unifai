#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/swift-local.sh build
app="$PWD/.build/Unifai.app"
if [[ "${1:-}" == "--fixture" ]]; then app="$PWD/.build/Unifai Fixtures.app"; fi
mkdir -p "$app/Contents/MacOS"
cp .build/debug/Unifai "$app/Contents/MacOS/Unifai"
# SwiftPM resource bundle (provider logos); Bundle.module finds it in Contents/Resources.
mkdir -p "$app/Contents/Resources"
rm -rf "$app/Contents/Resources/Unifai_Unifai.bundle"
cp -R .build/debug/Unifai_Unifai.bundle "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Unifai</string>
<key>CFBundleIdentifier</key><string>dev.unifai.local</string>
<key>CFBundleName</key><string>Unifai</string>
<key>CFBundleDisplayName</key><string>Unifai</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
if [[ "${1:-}" == "--fixture" ]]; then
    /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier dev.unifai.fixtures' "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleName Unifai Fixtures' "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Unifai Fixtures' "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Add :UnifaiFixtureMode bool true' "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :UnifaiDataDirectory string $PWD/.qa/fixture-workspace" "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Add :UnifaiKeychainCheck bool true' "$app/Contents/Info.plist"
fi
# Local ad-hoc signature only. No developer account, distribution or notarization.
codesign --force --sign - "$app"
printf 'Built %s\n' "$app"
