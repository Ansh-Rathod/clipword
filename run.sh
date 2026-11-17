#!/bin/bash
# Build and launch the Flutter Clipword app.
#
# Usage:
#   ./run.sh            # Debug run on macOS
#   ./run.sh Release    # Release mode

set -euo pipefail

cd "$(dirname "$0")/flutter"

CONFIGURATION="${1:-${CONFIGURATION:-Debug}}"
MODE_ARGS=()
if [ "$CONFIGURATION" = "Release" ] || [ "$CONFIGURATION" = "release" ]; then
  MODE_ARGS=(--release)
fi

echo "==> Running Clipword (Flutter macOS, $CONFIGURATION)..."
exec flutter run -d macos "${MODE_ARGS[@]}"
