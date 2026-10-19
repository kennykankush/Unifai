#!/bin/bash
# Assemble a Unifai.app bundle from a SwiftPM build.
# Usage: scripts/assemble-app.sh <debug|release> <dev|fixture|release> <output .app path>
#   dev      local development build: "Unifai Dev", separate data folder and Keychain service
#   fixture  synthetic demo workspace with networking disabled
#   release  the official app shipped through GitHub Releases and Homebrew
# Signing is left to the caller.
set -euo pipefail
cd "$(dirname "$0")/.."
config="$1"; channel="$2"; app="$3"
version="$(tr -d '[:space:]' < VERSION)"
build_number="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

bash scripts/swift-local.sh build -c "$config" >&2
bin="$(bash scripts/swift-local.sh build -c "$config" --show-bin-path)"

case "$channel" in
    release) identifier="dev.unifai.app"; name="Unifai" ;;
    dev) identifier="dev.unifai.dev"; name="Unifai Dev" ;;
    fixture) identifier="dev.unifai.fixtures"; name="Unifai Fixtures" ;;
    *) echo "Unknown channel: $channel" >&2; exit 64 ;;
esac

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Unifai" "$app/Contents/MacOS/Unifai"
cp "$bin/unifai-mcp" "$app/Contents/MacOS/unifai-mcp"
cp -R Sources/Unifai/Resources/Logos "$app/Contents/Resources/Logos"

# App icon: render the SwiftUI artwork once, then build every .icns size from it.
work="$(mktemp -d)"
iconset="$work/AppIcon.iconset"
mkdir -p "$iconset"
"$bin/Unifai" --export-icon "$work/icon.png"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$work/icon.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$work/icon.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
rm -rf "$work"

plist="$app/Contents/Info.plist"
cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Unifai</string>
<key>CFBundleIdentifier</key><string>$identifier</string>
<key>CFBundleName</key><string>$name</string>
<key>CFBundleDisplayName</key><string>$name</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$build_number</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.finance</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>UnifaiChannel</key><string>$channel</string>
</dict></plist>
PLIST
if [[ "$channel" == "fixture" ]]; then
    /usr/libexec/PlistBuddy -c 'Add :UnifaiFixtureMode bool true' "$plist"
    /usr/libexec/PlistBuddy -c "Add :UnifaiDataDirectory string $PWD/.qa/fixture-workspace" "$plist"
    /usr/libexec/PlistBuddy -c 'Add :UnifaiKeychainCheck bool true' "$plist"
fi
printf '%s\n' "$app"
