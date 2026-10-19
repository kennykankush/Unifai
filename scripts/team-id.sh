#!/bin/bash
# Print the Team ID of a code signing identity (SHA-1 or name), or of the first Developer ID
# Application identity when none is given. Prints nothing when there is no such identity.
set -euo pipefail
match="${1:-Developer ID Application}"
security find-identity -v -p codesigning | grep -F -- "$match" | head -1 | sed -nE 's/.*\(([A-Z0-9]{10})\)".*/\1/p'
