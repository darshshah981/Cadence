#!/bin/bash
set -euo pipefail
source_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$source_dir/../.." && pwd)"
output_dir="${1:-$repo_dir/Build/ComposeTestHost}"
app_path="$output_dir/ComposeTestHost.app"
mkdir -p "$app_path/Contents/MacOS"
xcrun swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
  -framework AppKit -framework WebKit -framework CryptoKit \
  "$source_dir/ComposeTestHost.swift" -o "$app_path/Contents/MacOS/ComposeTestHost"
cat > "$app_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.darshshah.Cadence.compose-test-host</string>
  <key>CFBundleExecutable</key><string>ComposeTestHost</string>
  <key>CFBundleName</key><string>Compose Test Host</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app_path"
printf '%s\n' "$app_path"
