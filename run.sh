#!/bin/bash
# Build and launch Clipword.
#
# Usage:
#   ./run.sh            # Debug build
#   ./run.sh Release    # Release build
#   CONFIGURATION=Release ./run.sh

set -euo pipefail

cd "$(dirname "$0")"

CONFIGURATION="${1:-${CONFIGURATION:-Debug}}"
SCHEME="Clipword"
BUILD_DIR=".build"
APP_NAME="Clipword.app"

# The Xcode project is generated; create it on a fresh clone.
if [ ! -f "Clipword.xcodeproj/project.pbxproj" ]; then
    echo "==> Xcode project not found, generating..."
    python3 generate_project.p y
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
open "$APP_PATH"
