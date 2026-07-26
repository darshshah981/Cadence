#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/Cadence.xcodeproj"
SCHEME="Cadence"
CONFIGURATION="${CONFIGURATION:-Debug}"
DESTINATION="${DESTINATION:-platform=macOS}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT_DIR/Build/DerivedData}"
INSTALL_PATH="${INSTALL_PATH:-/Applications/Cadence Debug.app}"
BUNDLE_ID="${BUNDLE_ID:-com.darshshah.Cadence.debug}"

load_optional_env_file() {
  local path="$1"
  if [[ -f "$path" ]]; then
    set -a
    # shellcheck source=/dev/null
    . "$path"
    set +a
  fi
}

load_optional_env_file "$HOME/.cadence/google-oauth.env"
load_optional_env_file "$ROOT_DIR/local/google-oauth.env"

GOOGLE_OAUTH_REDIRECT_SCHEME="${GOOGLE_OAUTH_REDIRECT_SCHEME:-$BUNDLE_ID}"

if [[ -z "${GOOGLE_OAUTH_CLIENT_ID:-}" ]]; then
  cat >&2 <<EOF
Google sign-in cannot be enabled because GOOGLE_OAUTH_CLIENT_ID is missing.

Create the ignored local configuration:
  $ROOT_DIR/local/google-oauth.env

Then add the Google desktop OAuth client settings documented in README.md and rerun:
  scripts/install_dev_app.sh
EOF
  exit 1
fi

echo "Building $SCHEME ($CONFIGURATION)..."
xcodebuild build \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  GOOGLE_OAUTH_CLIENT_ID="$GOOGLE_OAUTH_CLIENT_ID" \
  GOOGLE_OAUTH_CLIENT_SECRET="${GOOGLE_OAUTH_CLIENT_SECRET:-}" \
  GOOGLE_OAUTH_REDIRECT_SCHEME="$GOOGLE_OAUTH_REDIRECT_SCHEME" \
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

EMBEDDED_GOOGLE_OAUTH_CLIENT_ID="$(
  /usr/libexec/PlistBuddy -c 'Print :CadenceGoogleOAuthClientID' \
    "$SOURCE_APP/Contents/Info.plist" 2>/dev/null || true
)"
if [[ -z "$EMBEDDED_GOOGLE_OAUTH_CLIENT_ID" ]]; then
  echo "Refusing to install: the built app does not contain a Google OAuth client ID." >&2
  exit 1
fi

echo "Installing to $INSTALL_PATH..."
if [[ -n "$EXECUTABLE_NAME" ]]; then
  pkill -x "$EXECUTABLE_NAME" >/dev/null 2>&1 || true
fi
rm -rf "$INSTALL_PATH"
ditto "$SOURCE_APP" "$INSTALL_PATH"

echo "Launching $INSTALL_PATH..."
open -n "$INSTALL_PATH"

echo "Installed $FULL_PRODUCT_NAME to $INSTALL_PATH"
