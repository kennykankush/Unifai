#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Keep compiler and package caches inside this checkout, including manifest compilation.
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFT_MODULECACHE_PATH="$PWD/.build/ModuleCache"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
exec swift "$@" --disable-sandbox --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security"
