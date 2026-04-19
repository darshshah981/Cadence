#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/Cadence.xcodeproj"
SCHEME="Cadence"
CONFIGURATION="${CONFIGURATION:-Debug}"
DESTINATION="${DESTINATION:-platform=macOS}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT_DIR/Build/DerivedData}"
INSTALL_PATH="${INSTALL_PATH:-/Applications/Cadence Debug.app}"

echo "Building $SCHEME ($CONFIGURATION)..."
xcodebuild build \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  > /tmp/cadence-install-build.log

BUILD_SETTINGS="$(xcodebuild -project "$PROJECT_PATH" -scheme "$SCHEME" -configuration "$CONFIGURATION" -derivedDataPath "$DERIVED_DATA_PATH" -showBuildSettings)"
TARGET_BUILD_DIR="$(printf '%s\n' "$BUILD_SETTINGS" | awk -F' = ' '/TARGET_BUILD_DIR = / { print $2; exit }')"
FULL_PRODUCT_NAME="$(printf '%s\n' "$BUILD_SETTINGS" | awk -F' = ' '/FULL_PRODUCT_NAME = / { print $2; exit }')"
EXECUTABLE_NAME="$(printf '%s\n' "$BUILD_SETTINGS" | awk -F' = ' '/EXECUTABLE_NAME = / { print $2; exit }')"

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
if [[ -n "$EXECUTABLE_NAME" ]]; then
  pkill -x "$EXECUTABLE_NAME" >/dev/null 2>&1 || true
fi
rm -rf "$INSTALL_PATH"
ditto "$SOURCE_APP" "$INSTALL_PATH"

echo "Launching $INSTALL_PATH..."
open "$INSTALL_PATH"

echo "Installed $FULL_PRODUCT_NAME to $INSTALL_PATH"
