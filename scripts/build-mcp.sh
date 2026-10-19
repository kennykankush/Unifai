#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/swift-local.sh build -c release --product unifai-mcp
bin="$PWD/.build/release/unifai-mcp"
printf 'Built %s\n\nRegister with Claude Code:\n  claude mcp add --scope user unifai -- "%s"\n' "$bin" "$bin"
