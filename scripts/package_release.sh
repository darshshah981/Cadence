#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/Cadence.xcodeproj"
SCHEME="${SCHEME:-Cadence}"
CONFIGURATION="${CONFIGURATION:-Release}"
TEAM_ID="${TEAM_ID:-P3MT7UXJ5N}"
NOTARY_PROFILE="${NOTARY_PROFILE:-cadence-notary}"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/Build/Release}"
ARCHIVE_PATH="${ARCHIVE_PATH:-$BUILD_DIR/Cadence.xcarchive}"
EXPORT_PATH="${EXPORT_PATH:-$BUILD_DIR/Export}"
EXPORT_OPTIONS_PLIST="$BUILD_DIR/ExportOptions.plist"
SUBMISSION_ZIP="$BUILD_DIR/Cadence-notary.zip"
FINAL_ZIP="$BUILD_DIR/Cadence.zip"
SKIP_NOTARIZATION=0

usage() {
  cat <<EOF
Usage: scripts/package_release.sh [--skip-notarization]

Builds a Developer ID signed Cadence.app, optionally submits it to Apple for
notarization, staples the notarization ticket, validates Gatekeeper acceptance,
and creates Build/Release/Cadence.zip for distribution.

This script packages the Release app only. It must never be used to distribute
Cadence Debug.app.

Before running with notarization enabled, store credentials once:
  xcrun notarytool store-credentials "$NOTARY_PROFILE" --team-id "$TEAM_ID"

Environment overrides:
  TEAM_ID=$TEAM_ID
  NOTARY_PROFILE=$NOTARY_PROFILE
  BUILD_DIR=$BUILD_DIR
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-notarization)
      SKIP_NOTARIZATION=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

require_developer_id_certificate() {
  if ! security find-identity -p codesigning -v | grep -q "Developer ID Application"; then
    cat >&2 <<EOF
Missing a Developer ID Application signing certificate in this keychain.

Create or install one in Xcode:
  Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application

Then rerun:
  scripts/package_release.sh
EOF
    exit 1
  fi
}

require_notary_profile() {
  if [[ "$SKIP_NOTARIZATION" == "1" ]]; then
    return
  fi

  if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    cat >&2 <<EOF
Missing or invalid notarytool keychain profile: $NOTARY_PROFILE

Store credentials once:
  xcrun notarytool store-credentials "$NOTARY_PROFILE" --team-id "$TEAM_ID"

Then rerun:
  scripts/package_release.sh
EOF
    exit 1
  fi
}

require_developer_id_certificate
require_notary_profile

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$EXPORT_PATH"

cat > "$EXPORT_OPTIONS_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>signingStyle</key>
  <string>manual</string>
  <key>teamID</key>
  <string>$TEAM_ID</string>
  <key>stripSwiftSymbols</key>
  <true/>
</dict>
</plist>
EOF

echo "Archiving $SCHEME ($CONFIGURATION)..."
xcodebuild archive \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "generic/platform=macOS" \
  -archivePath "$ARCHIVE_PATH"

echo "Exporting Developer ID app..."
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS_PLIST"

APP_PATH="$EXPORT_PATH/Cadence.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Exported app not found at $APP_PATH" >&2
  exit 1
fi

DISPLAY_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)"
EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)"

if [[ "$DISPLAY_NAME" == *Debug* || "$BUNDLE_ID" == *debug* || "$EXECUTABLE_NAME" == *Debug* ]]; then
  cat >&2 <<EOF
Refusing to package a debug build:
  Display name: $DISPLAY_NAME
  Bundle ID: $BUNDLE_ID
  Executable: $EXECUTABLE_NAME

GitHub releases must ship Cadence.app from the Release configuration.
EOF
  exit 1
fi

echo "Verifying code signature..."
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign -dvvv --entitlements :- "$APP_PATH"

rm -f "$SUBMISSION_ZIP" "$FINAL_ZIP"

if [[ "$SKIP_NOTARIZATION" == "1" ]]; then
  echo "Skipping notarization. Creating unsigned-for-Gatekeeper validation zip..."
else
  echo "Creating notarization upload..."
  ditto -c -k --keepParent "$APP_PATH" "$SUBMISSION_ZIP"

  echo "Submitting to Apple notarization service..."
  xcrun notarytool submit "$SUBMISSION_ZIP" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

  echo "Stapling notarization ticket..."
  xcrun stapler staple "$APP_PATH"

  echo "Validating Gatekeeper acceptance..."
  spctl -a -vv "$APP_PATH"
fi

echo "Creating distribution zip..."
ditto -c -k --keepParent "$APP_PATH" "$FINAL_ZIP"

echo "Done:"
echo "  App: $APP_PATH"
echo "  Zip: $FINAL_ZIP"
