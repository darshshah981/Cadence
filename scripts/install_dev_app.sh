#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/Cadence.xcodeproj"
SCHEME="Cadence"
CONFIGURATION="${CONFIGURATION:-Debug}"
DESTINATION="${DESTINATION:-platform=macOS}"
INSTALL_PATH="${INSTALL_PATH:-/Applications/Cadence.app}"

echo "Building $SCHEME ($CONFIGURATION)..."
xcodebuild build \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "$DESTINATION" \
  > /tmp/cadence-install-build.log

BUILD_SETTINGS="$(xcodebuild -project "$PROJECT_PATH" -scheme "$SCHEME" -configuration "$CONFIGURATION" -showBuildSettings)"
TARGET_BUILD_DIR="$(printf '%s\n' "$BUILD_SETTINGS" | awk -F' = ' '/TARGET_BUILD_DIR = / { print $2; exit }')"
FULL_PRODUCT_NAME="$(printf '%s\n' "$BUILD_SETTINGS" | awk -F' = ' '/FULL_PRODUCT_NAME = / { print $2; exit }')"

if [[ -z "$TARGET_BUILD_DIR" || -z "$FULL_PRODUCT_NAME" ]]; then
  echo "Unable to resolve built app path." >&2
  exit 1
fi

SOURCE_APP="$TARGET_BUILD_DIR/$FULL_PRODUCT_NAME"

if [[ ! -d "$SOURCE_APP" ]]; then
  echo "Built app not found at $SOURCE_APP" >&2
  exit 1
fi

echo "Installing to $INSTALL_PATH..."
pkill -f 'Cadence.app/Contents/MacOS/Cadence' >/dev/null 2>&1 || true
rm -rf "$INSTALL_PATH"
ditto "$SOURCE_APP" "$INSTALL_PATH"

echo "Launching $INSTALL_PATH..."
open "$INSTALL_PATH"

echo "Installed Cadence to $INSTALL_PATH"
