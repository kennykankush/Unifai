#!/bin/bash
# Build, sign, notarize and publish an official Unifai release, then update the Homebrew tap.
#
# Usage:
#   scripts/release.sh            full release of the version in VERSION
#   scripts/release.sh --dry-run  build, sign and verify locally; no notarization, tag or upload
#   scripts/release.sh --skip-notarize
#                                 publish a Developer ID signed build without notarization (first launch
#                                 then needs Open Anyway); use only while notarization is unavailable
#
# One-time setup on the release Mac:
#   1. A "Developer ID Application" certificate in the login keychain (Xcode > Settings > Accounts).
#   2. Notarization credentials saved as a keychain profile:
#        xcrun notarytool store-credentials unifai --apple-id <apple id> --team-id <team id>
#      (uses an app-specific password from account.apple.com)
#   3. gh signed in with permission to push to this repository and the tap.
#
# Overrides: UNIFAI_SIGNING_IDENTITY, UNIFAI_NOTARY_PROFILE (default "unifai"), UNIFAI_TAP (default <owner>/homebrew-tap).
set -euo pipefail
cd "$(dirname "$0")/.."

dry_run=0; notarize=1
case "${1:-}" in
    --dry-run) dry_run=1 ;;
    --skip-notarize) notarize=0 ;;
    "") ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; exit 64 ;;
esac

version="$(tr -d '[:space:]' < VERSION)"
tag="v$version"
profile="${UNIFAI_NOTARY_PROFILE:-unifai}"
repo="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
owner="${repo%%/*}"
tap="${UNIFAI_TAP:-$owner/homebrew-tap}"
app="$PWD/dist/Unifai.app"
zip="$PWD/dist/Unifai-$version.zip"

step() { printf '\n==> %s\n' "$1"; }
fail() { printf 'error: %s\n' "$1" >&2; exit 1; }

identity="${UNIFAI_SIGNING_IDENTITY:-}"
if [[ -z "$identity" ]]; then
    identity="$(security find-identity -v -p codesigning | awk '/Developer ID Application/ { print $2; exit }')"
fi
[[ -n "$identity" ]] || fail "No Developer ID Application certificate found. Set UNIFAI_SIGNING_IDENTITY."

if (( ! dry_run )); then
    step "Checking release preconditions for $tag"
    [[ "$(git branch --show-current)" == "main" ]] || fail "Release from main."
    git diff --quiet && git diff --cached --quiet || fail "Commit or stash changes first."
    git fetch -q origin main --tags
    [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || fail "Push main before releasing."
    if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then fail "$tag already exists. Bump VERSION."; fi
    (( ! notarize )) || xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1 \
        || fail "Notary profile '$profile' not found. Run: xcrun notarytool store-credentials $profile --apple-id <id> --team-id <team>"
fi

step "Running tests"
bash scripts/swift-local.sh test >/dev/null

step "Assembling Unifai $version (release build)"
rm -rf dist && mkdir -p dist
export UNIFAI_TEAM_ID="$(bash scripts/team-id.sh "$identity")"
[[ -n "$UNIFAI_TEAM_ID" ]] || fail "Could not read the Team ID of the signing identity."
bash scripts/assemble-app.sh release release "$app" >/dev/null

step "Signing with Developer ID (hardened runtime)"
bash scripts/sign-app.sh "$app" "$identity" --release
codesign --verify --strict --verbose=2 "$app"

package() { rm -f "$zip"; ditto -c -k --keepParent "$app" "$zip"; }
package

if (( dry_run )); then
    step "Dry run complete"
    printf 'Signed app: %s\nArchive:    %s\nNot notarized, tagged or published.\n' "$app" "$zip"
    exit 0
fi

if (( notarize )); then
    step "Notarizing (this usually takes a few minutes)"
    result="$(xcrun notarytool submit "$zip" --keychain-profile "$profile" --wait --output-format json)"
    status="$(printf '%s' "$result" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))')"
    if [[ "$status" != "Accepted" ]]; then
        submission="$(printf '%s' "$result" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))')"
        [[ -n "$submission" ]] && xcrun notarytool log "$submission" --keychain-profile "$profile" >&2 || true
        fail "Notarization status: ${status:-unknown}"
    fi
    xcrun stapler staple "$app"
    spctl --assess --type execute --verbose=2 "$app"
    package
fi
sha="$(shasum -a 256 "$zip" | awk '{ print $1 }')"

step "Publishing $tag to GitHub"
previous="$(git describe --tags --abbrev=0 2>/dev/null || true)"
notes="$(mktemp)"
{
    printf 'Install or update with Homebrew:\n\n```sh\nbrew install --cask %s/unifai\nbrew upgrade --cask unifai\n```\n\n' "${tap/homebrew-/}"
    if (( notarize )); then
        printf 'Signed with Developer ID and notarized by Apple. Apple silicon, macOS 14 or later.\n\n## Changes\n\n'
    else
        printf 'Signed with Developer ID but **not notarized**. On first launch macOS will block it once: open System Settings > Privacy & Security and click Open Anyway. Apple silicon, macOS 14 or later.\n\n## Changes\n\n'
    fi
    if [[ -n "$previous" ]]; then git log --no-merges --format='- %s' "$previous..HEAD"; else git log --no-merges --format='- %s'; fi
} > "$notes"
git tag -a "$tag" -m "Unifai $version"
git push -q origin "$tag"
gh release create "$tag" "$zip" --title "Unifai $version" --notes-file "$notes"
rm -f "$notes"

step "Updating Homebrew tap $tap"
if ! gh repo view "$tap" >/dev/null 2>&1; then
    gh repo create "$tap" --public --description "Homebrew tap for Unifai" >/dev/null
fi
caveats=""
if (( ! notarize )); then
    caveats=$'\n  caveats <<~EOS\n    This build is signed with Developer ID but not notarized.\n    If macOS blocks the first launch, open System Settings > Privacy & Security\n    and click Open Anyway.\n  EOS\n'
fi
work="$(mktemp -d)"
git clone -q "https://github.com/$tap.git" "$work/tap" 2>/dev/null || { mkdir -p "$work/tap"; git -C "$work/tap" init -q -b main; git -C "$work/tap" remote add origin "https://github.com/$tap.git"; }
mkdir -p "$work/tap/Casks"
cat > "$work/tap/Casks/unifai.rb" <<CASK
cask "unifai" do
  version "$version"
  sha256 "$sha"

  url "https://github.com/$repo/releases/download/v#{version}/Unifai-#{version}.zip"
  name "Unifai"
  desc "Local hub for AI wallets, spend, renewals and releases, with a read-only MCP server"
  homepage "https://github.com/$repo"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Unifai.app"
  binary "#{appdir}/Unifai.app/Contents/MacOS/unifai-mcp"

  uninstall quit: "dev.unifai.app"
$caveats
  zap trash: [
    "~/Library/Application Support/Unifai",
    "~/Library/Preferences/dev.unifai.app.plist",
  ]
end
CASK
if [[ ! -f "$work/tap/README.md" ]]; then
    cat > "$work/tap/README.md" <<README
# Homebrew tap

\`\`\`sh
brew install --cask ${tap/homebrew-/}/unifai
\`\`\`

Update with \`brew upgrade --cask unifai\`. Source: https://github.com/$repo
README
fi
git -C "$work/tap" add -A
git -C "$work/tap" commit -q -m "unifai $version"
git -C "$work/tap" push -q origin HEAD:main
rm -rf "$work"

step "Released Unifai $version"
printf 'Release: https://github.com/%s/releases/tag/%s\nInstall: brew install --cask %s/unifai\n' "$repo" "$tag" "${tap/homebrew-/}"
