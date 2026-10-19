#!/bin/bash
# Local development build. Produces .build/Unifai Dev.app, which keeps its own data folder
# (~/Library/Application Support/Unifai Dev) and Keychain service, so it never touches the
# official Unifai installed through Homebrew. Pass --fixture for the synthetic demo workspace.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${1:-}" == "--fixture" ]]; then
    app="$PWD/.build/Unifai Fixtures.app"; channel=fixture
else
    app="$PWD/.build/Unifai Dev.app"; channel=dev
fi
bash scripts/assemble-app.sh debug "$channel" "$app" >/dev/null
# Local ad-hoc signature only. Official releases are signed and notarized by scripts/release.sh.
codesign --force --sign - "$app/Contents/MacOS/unifai-mcp"
codesign --force --sign - "$app"
printf 'Built %s\n' "$app"
