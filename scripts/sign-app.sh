#!/bin/bash
# Sign an assembled Unifai.app from the inside out: the MCP server, the widget extension
# (sandboxed, with the shared app group), then the app (same app group).
# Usage: scripts/sign-app.sh <app> <identity> [--release]
#   --release adds the hardened runtime and a secure timestamp, as notarization requires.
# Without a Team ID (ad-hoc identity "-") the app is signed without entitlements and has no widget.
set -euo pipefail
cd "$(dirname "$0")/.."
app="$1"; identity="$2"; release="${3:-}"
flags=(--force --sign "$identity")
if [[ "$release" == "--release" ]]; then flags+=(--options runtime --timestamp); fi

team="${UNIFAI_TEAM_ID:-}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
codesign "${flags[@]}" "$app/Contents/MacOS/unifai-mcp"
if [[ -n "$team" && "$identity" != "-" ]]; then
    sed "s/TEAM_ID/$team/" scripts/entitlements/widget.entitlements > "$work/widget.entitlements"
    sed "s/TEAM_ID/$team/" scripts/entitlements/app.entitlements > "$work/app.entitlements"
    if [[ -d "$app/Contents/PlugIns/UnifaiWidget.appex" ]]; then
        codesign "${flags[@]}" --entitlements "$work/widget.entitlements" "$app/Contents/PlugIns/UnifaiWidget.appex"
    fi
    codesign "${flags[@]}" --entitlements "$work/app.entitlements" "$app"
else
    rm -rf "$app/Contents/PlugIns"
    codesign "${flags[@]}" "$app"
fi
codesign --verify --strict --deep "$app"
