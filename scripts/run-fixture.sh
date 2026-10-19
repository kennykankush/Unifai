#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/build-app.sh --fixture
open "$PWD/.build/Unifai Fixtures.app"
