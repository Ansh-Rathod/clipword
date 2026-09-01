#!/bin/bash
# Build and launch Clipword.
#
# Usage:
#   ./run.sh            # Debug build + run in foreground (logs visible)
#   ./run.sh Release    # Release build
#   LOGS=0 ./run.sh     # Launch detached via `open` (no logs)

set -euo pipefail

cd "$(dirname "$0")"

CONFIGURATION="${1:-${CONFIGURATION:-Debug}}"
SCHEME="Clipword"
BUILD_DIR=".build"
APP_NAME="Clipword.app"

# The Xcode project is generated; create it on a fresh clone.
if [ ! -f "Clipword.xcodeproj/project.pbxproj" ]; then
    echo "==> Xcode project not found, generating..."
    python3 generate_project.py
fi

echo "==> Building Clipword ($CONFIGURATION)..."
xcodebuild \
    -project Clipword.xcodeproj \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$BUILD_DIR" \
    build

APP_PATH="$BUILD_DIR/Build/Products/$CONFIGURATION/$APP_NAME"
if [ ! -d "$APP_PATH" ]; then
    echo "error: built app not found at $APP_PATH" >&2
    exit 1
fi

echo "==> Launching $APP_PATH"
if [ "${LOGS:-1}" = "1" ]; then
    # Run the binary directly so stdout/stderr (print, os_log fallbacks,
    # crashes) stream to this terminal. Ctrl-C quits the app.
    exec "$APP_PATH/Contents/MacOS/Clipword"
else
    open "$APP_PATH"
fi
