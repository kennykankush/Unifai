#!/bin/bash
# Assemble a Unifai.app bundle from a SwiftPM build.
# Usage: scripts/assemble-app.sh <debug|release> <dev|fixture|release> <output .app path>
#   dev      local development build: "Unifai Dev", separate data folder and Keychain service
#   fixture  synthetic demo workspace with networking disabled
#   release  the official app shipped through GitHub Releases and Homebrew
# With UNIFAI_TEAM_ID set, the desktop widget extension is embedded and both bundles name the
# shared app group "<Team ID>.dev.unifai". Signing is left to the caller (scripts/sign-app.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
config="$1"; channel="$2"; app="$3"
version="$(tr -d '[:space:]' < VERSION)"
build_number="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

bash scripts/swift-local.sh build -c "$config" >&2
bin="$(bash scripts/swift-local.sh build -c "$config" --show-bin-path)"

case "$channel" in
    release) identifier="dev.unifai.app"; name="Unifai"; scheme="unifai" ;;
    dev) identifier="dev.unifai.dev"; name="Unifai Dev"; scheme="unifai-dev" ;;
    fixture) identifier="dev.unifai.fixtures"; name="Unifai Fixtures"; scheme="unifai-fixtures" ;;
    *) echo "Unknown channel: $channel" >&2; exit 64 ;;
esac
team="${UNIFAI_TEAM_ID:-}"
group="${team:+$team.dev.unifai}"

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
<key>UnifaiURLScheme</key><string>$scheme</string>
<key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>$identifier</string>
    <key>CFBundleURLSchemes</key><array><string>$scheme</string></array>
</dict></array>
</dict></plist>
PLIST
if [[ -n "$group" ]]; then
    /usr/libexec/PlistBuddy -c "Add :UnifaiAppGroup string $group" "$plist"
fi

# Desktop widgets (not in the synthetic demo, so it never adds widgets to the gallery).
if [[ -n "$group" && "$channel" != "fixture" ]]; then
    appex="$app/Contents/PlugIns/UnifaiWidget.appex"
    mkdir -p "$appex/Contents/MacOS" "$appex/Contents/Resources"
    cp "$bin/UnifaiWidget" "$appex/Contents/MacOS/UnifaiWidget"
    cp -R Sources/Unifai/Resources/Logos "$appex/Contents/Resources/Logos"
    cat > "$appex/Contents/Info.plist" <<APPEX
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
<key>CFBundleExecutable</key><string>UnifaiWidget</string>
<key>CFBundleIdentifier</key><string>$identifier.widget</string>
<key>CFBundleName</key><string>$name</string>
<key>CFBundleDisplayName</key><string>$name</string>
<key>CFBundlePackageType</key><string>XPC!</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$build_number</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSExtension</key><dict>
    <key>NSExtensionPointIdentifier</key><string>com.apple.widgetkit-extension</string>
</dict>
<key>UnifaiChannel</key><string>$channel</string>
<key>UnifaiAppGroup</key><string>$group</string>
<key>UnifaiURLScheme</key><string>$scheme</string>
</dict></plist>
APPEX
fi
if [[ "$channel" == "fixture" ]]; then
    /usr/libexec/PlistBuddy -c 'Add :UnifaiFixtureMode bool true' "$plist"
    /usr/libexec/PlistBuddy -c "Add :UnifaiDataDirectory string $PWD/.qa/fixture-workspace" "$plist"
    /usr/libexec/PlistBuddy -c 'Add :UnifaiKeychainCheck bool true' "$plist"
fi
printf '%s\n' "$app"
