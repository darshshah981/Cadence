#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/Cadence.xcodeproj"
SCHEME="Cadence"
CONFIGURATION="${CONFIGURATION:-Debug}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/private/tmp/CadenceDerivedData}"
PRODUCT_NAME="${PRODUCT_NAME:-Cadence Debug}"
APP_BUNDLE="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$PRODUCT_NAME.app"
APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/$PRODUCT_NAME"
BUNDLE_ID="${BUNDLE_ID:-com.darshshah.Cadence.debug}"
INSTALL_APP_BUNDLE="${INSTALL_APP_BUNDLE:-/Applications/$PRODUCT_NAME.app}"
INSTALL_APP_EXECUTABLE="$INSTALL_APP_BUNDLE/Contents/MacOS/$PRODUCT_NAME"

usage() {
    echo "usage: $0 [run|--verify|--test|--audio-smoke|--google-config|--logs|--telemetry|--debug]" >&2
}

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

stop_app() {
  pkill -f "Cadence Debug.app/Contents/MacOS/Cadence Debug" >/dev/null 2>&1 || true
  pkill -f "Cadence.app/Contents/MacOS/Cadence" >/dev/null 2>&1 || true
  pkill -f "$APP_EXECUTABLE" >/dev/null 2>&1 || true
  pkill -f "$INSTALL_APP_EXECUTABLE" >/dev/null 2>&1 || true
  pkill -x "$PRODUCT_NAME" >/dev/null 2>&1 || true
}

build_app() {
  xcodebuild build \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "platform=macOS" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    GOOGLE_OAUTH_CLIENT_ID="${GOOGLE_OAUTH_CLIENT_ID:-}" \
    GOOGLE_OAUTH_CLIENT_SECRET="${GOOGLE_OAUTH_CLIENT_SECRET:-}" \
    GOOGLE_OAUTH_REDIRECT_SCHEME="$GOOGLE_OAUTH_REDIRECT_SCHEME" \
    -quiet
}

test_app() {
  xcodebuild test \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "platform=macOS" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    GOOGLE_OAUTH_CLIENT_ID="${GOOGLE_OAUTH_CLIENT_ID:-}" \
    GOOGLE_OAUTH_CLIENT_SECRET="${GOOGLE_OAUTH_CLIENT_SECRET:-}" \
    GOOGLE_OAUTH_REDIRECT_SCHEME="$GOOGLE_OAUTH_REDIRECT_SCHEME" \
    -quiet
}

google_config() {
  echo "Bundle ID: $BUNDLE_ID"
  echo "Google OAuth redirect: desktop loopback on 127.0.0.1 during sign-in"
  if [[ -n "${GOOGLE_OAUTH_CLIENT_ID:-}" ]]; then
    echo "Google OAuth client ID: configured"
  else
    echo "Google OAuth client ID: missing"
    echo "Create local/google-oauth.env with GOOGLE_OAUTH_CLIENT_ID=<your desktop OAuth client ID>."
    return 1
  fi
  if [[ -n "${GOOGLE_OAUTH_CLIENT_SECRET:-}" ]]; then
    echo "Google OAuth client secret: configured"
  else
    echo "Google OAuth client secret: missing"
  fi
}

install_app() {
  /usr/bin/ditto "$APP_BUNDLE" "$INSTALL_APP_BUNDLE"
}

open_app() {
  if [[ -n "${CADENCE_VERIFY_TOKEN:-}" ]]; then
    /usr/bin/open -n "$INSTALL_APP_BUNDLE" --args --cadence-verify-token "$CADENCE_VERIFY_TOKEN"
  else
    /usr/bin/open -n "$INSTALL_APP_BUNDLE"
  fi
}

verify_process() {
  local attempts=0
  until pgrep -f "$INSTALL_APP_EXECUTABLE" >/dev/null 2>&1 || pgrep -x "$PRODUCT_NAME" >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    if [[ "$attempts" -gt 30 ]]; then
      echo "Cadence did not stay running." >&2
      exit 1
    fi
    sleep 0.2
  done
}

verify_main_window() {
  local token="$1"
  local verifier
  verifier="$(mktemp "${TMPDIR:-/tmp}/cadence-window-check.XXXXXX.swift")"
  cat > "$verifier" <<'SWIFT'
import CoreGraphics
import Foundation

guard CommandLine.arguments.count >= 3,
      let pid = Int(CommandLine.arguments[1]) else {
    exit(2)
}

let expectedTitle = CommandLine.arguments[2]
let options = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
let windows = CGWindowListCopyWindowInfo(options, CGWindowID(0)) as? [[String: Any]] ?? []
let foundWindow = windows.contains { window in
    guard (window[kCGWindowOwnerPID as String] as? Int) == pid,
          (window[kCGWindowLayer as String] as? Int) == 0,
          (window[kCGWindowIsOnscreen as String] as? Bool) == true else {
        return false
    }
    return (window[kCGWindowName as String] as? String) == expectedTitle
}

exit(foundWindow ? 0 : 1)
SWIFT
  trap 'rm -f "$verifier"' RETURN
  local attempts=0
  until pid="$(pgrep -f "$INSTALL_APP_EXECUTABLE" | tail -n 1)" && [[ -n "$pid" ]] && /usr/bin/swift "$verifier" "$pid" "Cadence" >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    if [[ "$attempts" -gt 30 ]]; then
      echo "Cadence is running, but WindowServer did not report a visible main window." >&2
      exit 1
    fi
    sleep 0.5
  done
}

case "$MODE" in
  run)
    stop_app
    build_app
    install_app
    open_app
    ;;
  --verify|verify)
    stop_app
    build_app
    install_app
    export CADENCE_VERIFY_TOKEN="verify-$(date +%s)-$$"
    open_app
    verify_process
    verify_main_window "$CADENCE_VERIFY_TOKEN"
    echo "Cadence launched and exposed its main window."
    ;;
  --test|test)
    test_app
    ;;
  --google-config|google-config)
    google_config
    ;;
  --audio-smoke|audio-smoke)
    stop_app
    build_app
    install_app
    SMOKE_RESULT="/tmp/cadence-system-audio-smoke-$$.txt"
    rm -f "$SMOKE_RESULT"
    /usr/bin/open -n "$INSTALL_APP_BUNDLE" --args --cadence-system-audio-smoke "$SMOKE_RESULT"
    attempts=0
    until [[ -s "$SMOKE_RESULT" ]]; do
      attempts=$((attempts + 1))
      if [[ "$attempts" -gt 40 ]]; then
        echo "System audio smoke did not produce a result file." >&2
        exit 1
      fi
      sleep 0.5
    done
    cat "$SMOKE_RESULT"
    if grep -q '^error=' "$SMOKE_RESULT"; then
      exit 1
    fi
    ;;
  --logs|logs)
    stop_app
    build_app
    install_app
    open_app
    verify_process
    /usr/bin/log stream --info --style compact --predicate "process == \"$PRODUCT_NAME\""
    ;;
  --telemetry|telemetry)
    stop_app
    build_app
    install_app
    open_app
    verify_process
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --debug|debug)
    stop_app
    build_app
    lldb -- "$APP_EXECUTABLE"
    ;;
  *)
    usage
    exit 2
    ;;
esac
