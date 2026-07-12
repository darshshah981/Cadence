#!/usr/bin/env bash
# Focused Adaptive Scribe contract suite (U12 deterministic wrapper).
# Runs provider, migration, app, identity, guidance, lifecycle, control,
# diagnostic, privacy, and release-fixture isolation tests without live credentials.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT_DIR/.derived-data-contracts}"
SCHEME="${SCHEME:-Cadence}"
CONFIGURATION="${CONFIGURATION:-Debug}"
DESTINATION="${DESTINATION:-platform=macOS}"

if [[ ! -f "$ROOT_DIR/Cadence.xcodeproj/project.pbxproj" ]]; then
  echo "Generating Xcode project…"
  xcodegen generate
fi

# Swift Testing filter: match focused Adaptive Scribe suites by type name.
# Keep this list credential-free and offline.
FILTERS=(
  "AdaptiveScribeContractTests"
  "AdaptiveScribeFeatureGateTests"
  "ApplicationConfigurationTests"
  "ApplicationConfigurationMigrationTests"
  "ApplicationIconResolverTests"
  "CadenceControlSemanticsTests"
  "CustomGuidanceTests"
  "FixedOriginScribeProviderTests"
  "FocusedApplicationMonitorTests"
  "InstalledApplicationCatalogTests"
  "ReleaseFixtureIsolationTests"
  "ScribeActionPolicyTests"
  "ScribeContextServiceTests"
  "ScribeCoordinatorTests"
  "ScribeCredentialStoreTests"
  "ScribeDiagnosticsTests"
  "ScribeGuidanceTests"
  "ScribeHTTPTransportTests"
  "ScribeLiteralNormalizerTests"
  "ScribeMigrationTests"
  "ScribeModelCatalogServiceTests"
  "ScribePrivacyTests"
  "ScribeProviderConfigurationTests"
  "ScribeProviderConnectionManagerTests"
  "ScribeProviderConsentTests"
  "ScribeProviderControllerTests"
  "ScribeProviderLibraryTests"
  "ScribeProviderRuntimeTests"
  "ScribeProviderSetupModelTests"
  "ScribeProviderTests"
  "ScribeTests"
  "ScribeDomainIsolationTests"
)

ONLY_TESTING_ARGS=()
for filter in "${FILTERS[@]}"; do
  ONLY_TESTING_ARGS+=("-only-testing:CadenceTests/${filter}")
done

echo "Running Adaptive Scribe focused contract suites…"
set +e
xcodebuild test \
  -project Cadence.xcodeproj \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  "${ONLY_TESTING_ARGS[@]}"
status=$?
set -e

LOG_DIR="$DERIVED_DATA_PATH/Logs/Test"
if [[ -d "$LOG_DIR" ]]; then
  echo "Scanning contract test logs for privacy canaries…"
  bash "$ROOT_DIR/scripts/verify_scribe_privacy_canaries.sh" "$LOG_DIR"
else
  echo "Warning: no test log directory at $LOG_DIR; skipped canary scan." >&2
fi

if [[ "$status" -ne 0 ]]; then
  echo "Adaptive Scribe contract suite failed (exit $status)." >&2
  exit "$status"
fi

echo "Adaptive Scribe contract suites passed."
