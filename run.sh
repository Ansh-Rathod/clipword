#!/bin/bash
# Build and launch the Flutter Clipword app.
#
# Usage:
#   ./run.sh            # Debug run
#   ./run.sh Release    # Release mode

set -euo pipefail

cd "$(dirname "$0")"

CONFIGURATION="${1:-${CONFIGURATION:-Debug}}"
MODE_ARGS=()
if [ "$CONFIGURATION" = "Release" ] || [ "$CONFIGURATION" = "release" ]; then
  MODE_ARGS=(--release)
fi

case "$(uname -s)" in
  Darwin*)                 DEVICE=macos ;;
  MINGW*|MSYS*|CYGWIN*)    DEVICE=windows ;;
  *) echo "Unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac

if command -v fvm >/dev/null 2>&1; then
  FLUTTER=(fvm flutter)
else
  FLUTTER=(flutter)
fi

echo "==> Running Clipword (Flutter $DEVICE, $CONFIGURATION)..."
if [ ${#MODE_ARGS[@]} -gt 0 ]; then
  exec "${FLUTTER[@]}" run -d "$DEVICE" "${MODE_ARGS[@]}"
else
  exec "${FLUTTER[@]}" run -d "$DEVICE"
fi
