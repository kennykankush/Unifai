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
# Sign with the Developer ID certificate when this Mac has one: the widget's shared app group needs
# a Team ID, and a stable signature stops Keychain prompts after every rebuild. Otherwise ad hoc,
# without the widget. Official releases are signed and notarized by scripts/release.sh.
identity="$(security find-identity -v -p codesigning | awk '/Developer ID Application/ { print $2; exit }')"
export UNIFAI_TEAM_ID="${identity:+$(bash scripts/team-id.sh "$identity")}"
bash scripts/assemble-app.sh debug "$channel" "$app" >/dev/null
bash scripts/sign-app.sh "$app" "${identity:--}"
printf 'Built %s\n' "$app"
