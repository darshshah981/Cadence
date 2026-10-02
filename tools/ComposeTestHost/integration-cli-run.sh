#!/bin/bash
# Runs the production insertion suite in a standalone development executable.
# The executable and synthetic host both remain local, temporary artifacts.
set -euo pipefail

if [[ "$#" -ne 1 || ( "$1" != "--check" && "$1" != "--run" ) ]]; then
  printf '%s\n' 'Usage: bash tools/ComposeTestHost/integration-cli-run.sh --check|--run' >&2
  exit 2
fi
mode="$1"
source_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$source_dir/../.." && pwd)"
cd "$repo_dir"

derived_data="${CADENCE_INTEGRATION_DERIVED_DATA:-$repo_dir/.derived-data-contracts}"
products="$derived_data/Build/Products/Debug"
app_macos="$products/Cadence Debug.app/Contents/MacOS"
generated_maps="$derived_data/Build/Intermediates.noindex/GeneratedModuleMaps/yyjson.modulemap"
testing_frameworks="$(xcrun --show-sdk-platform-path)/Developer/Library/Frameworks"
swiftc_path="$(xcrun --find swiftc)"
toolchain_usr="$(cd "$(dirname "$swiftc_path")/.." && pwd)"
testing_plugin="$toolchain_usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
runner_dir="$repo_dir/Build/ComposeRoadmap/U5-cli-runner"
runner="$runner_dir/compose-insertion-runner"
mkdir -p "$runner_dir"

xcodegen generate > "$runner_dir/xcodegen.log" 2>&1
xcodebuild build -project Cadence.xcodeproj -scheme Cadence -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$derived_data" CODE_SIGNING_ALLOWED=NO \
  > "$runner_dir/build.log" 2>&1
bash "$source_dir/build.sh" > "$runner_dir/host-build.log" 2>&1

xcrun swiftc -parse-as-library -swift-version 5 \
  -I "$products" -F "$products/PackageFrameworks" -F "$testing_frameworks" \
  -load-plugin-library "$testing_plugin" \
  -Xcc "-fmodule-map-file=$generated_maps" \
  -Xlinker -rpath -Xlinker "$app_macos" \
  -Xlinker -rpath -Xlinker "$products/PackageFrameworks" \
  -Xlinker -rpath -Xlinker "$testing_frameworks" \
  "$source_dir/integration-cli-main.swift" \
  "$repo_dir/CadenceTests/ComposeInsertionIntegrationTests.swift" \
  "$app_macos/Cadence Debug.debug.dylib" \
  -o "$runner"

if [[ "$mode" == "--check" ]]; then
  printf 'Standalone production insertion runner compiled: %s\n' "$runner"
  exit 0
fi

evidence_dir="$(mktemp -d "${TMPDIR:-/tmp}/cadence-compose-U5-cli.XXXXXX")"
archive_dir="$repo_dir/Build/ComposeRoadmap/$(basename "$evidence_dir")"
report_path="$evidence_dir/integration-report.json"
ditto "$repo_dir/Build/ComposeTestHost/ComposeTestHost.app" "$evidence_dir/ComposeTestHost.app"

set +e
CADENCE_COMPOSE_INSERTION_INTEGRATION=1 \
CADENCE_COMPOSE_INSERTION_REPORT="$report_path" \
CADENCE_COMPOSE_TEST_HOST_APP="$evidence_dir/ComposeTestHost.app" \
CADENCE_COMPOSE_TEST_HOST_RUN="$evidence_dir/host-control" \
"$runner" > "$evidence_dir/runner.log" 2>&1
runner_status=$?
set -e

set +e
python3 - "$report_path" "$runner_status" <<'PY'
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
runner_status = int(sys.argv[2])
try:
    report = json.loads(path.read_text(encoding="utf-8"))
except (OSError, ValueError):
    print(json.dumps({"integrationPassed": False, "status": "missing_evidence"}))
    sys.exit(1)
cases = report.get("cases", [])
passed = (runner_status == 0 and report.get("schemaVersion") == 1
          and report.get("syntheticOnly") is True
          and report.get("status") == "passed"
          and report.get("accessibilityTrustedInActualTestProcess") is True
          and report.get("expectedCaseCount") == 18
          and report.get("completedCaseCount") == 18
          and report.get("passedCaseCount") == 18
          and report.get("failedCaseCount") == 0
          and len(cases) == 18
          and all(case.get("status") == "passed" for case in cases)
          and bool(report.get("hostBinarySHA256")))
status = report.get("status", "unknown")
print(json.dumps({"integrationPassed": passed, "status": status,
                  "passedCases": report.get("passedCaseCount", 0),
                  "report": str(path)}, sort_keys=True))
sys.exit(0 if passed else 3 if status == "blocked_permission" else 4 if status == "blocked_desktop" else 1)
PY
verification_status=$?
set -e
ditto "$evidence_dir" "$archive_dir"
printf 'Evidence archived: %s\n' "$archive_dir"
exit "$verification_status"
