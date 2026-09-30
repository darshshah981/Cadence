#!/bin/bash
# Current-source TextEdit identity and insertion proof using a synthetic file.
set -euo pipefail

if [[ "$#" -ne 1 || ( "$1" != "--check" && "$1" != "--run" ) ]]; then
  echo 'Usage: bash tools/ComposeTextEditSurfaceProbe/run.sh --check|--run' >&2
  exit 2
fi
mode="$1"
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
evidence="$root/Build/ComposeRoadmap/U17-textedit-surface"
derived="${CADENCE_INTEGRATION_DERIVED_DATA:-$root/.derived-data-contracts}"
products="$derived/Build/Products/Debug"
library="$products/Cadence Debug.app/Contents/MacOS/Cadence Debug.debug.dylib"
binary="$evidence/compose-textedit-probe"
mkdir -p "$evidence"

xcodegen generate > "$evidence/xcodegen.log" 2>&1
xcodebuild build -project Cadence.xcodeproj -scheme Cadence -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO \
  > "$evidence/build.log" 2>&1
xcrun swiftc -parse-as-library -swift-version 5 \
  -I "$products" -F "$products/PackageFrameworks" \
  -Xcc "-fmodule-map-file=$derived/Build/Intermediates.noindex/GeneratedModuleMaps/yyjson.modulemap" \
  -Xlinker -rpath -Xlinker "$products/Cadence Debug.app/Contents/MacOS" \
  -Xlinker -rpath -Xlinker "$products/PackageFrameworks" \
  tools/ComposeTextEditSurfaceProbe/main.swift "$library" -o "$binary"

if [[ "$mode" == "--check" ]]; then
  echo 'TextEdit production-service probe compiled; no app launched.'
  exit 0
fi

fixture_dir="$(mktemp -d /tmp/cadence-compose-textedit.XXXXXX)"
run_dir="$(mktemp -d "$evidence/run.XXXXXX")"
report_path="$run_dir/report.json"
printf '%s\n' 'SYNTHETIC TextEdit document for Cadence insertion verification.' \
  > "$fixture_dir/Synthetic.txt"
set +e
probe_output="$("$binary" "$fixture_dir/Synthetic.txt" 2>/dev/null)"
probe_status=$?
set -e

python3 - "$report_path" "$probe_output" "$probe_status" \
  "$library" "$binary" <<'PY'
import hashlib
import json
from pathlib import Path
import subprocess
import sys

report_path, output, exit_status, library, binary = sys.argv[1:]
success = output == "status=passed identity=true insertion=true exact_readback=true selection=true exact_replacement=true" and exit_status == "0"
allowed_failures = {
    "blockedDesktop", "accessibilityDenied", "invalidFixture", "wrongApplication",
    "noFocusedEditor", "cannotSetCaret", "identityRejected", "insertionRejected",
    "selectedCaptureRejected", "selectedReplacementRejected",
    "insertionReadbackMismatch", "replacementReadbackMismatch",
}
fields = dict(part.split("=", 1) for part in output.split() if "=" in part)
observed_failure = fields.get("reason", "") if fields.get("status") == "failed" else ""
failure = observed_failure if observed_failure in allowed_failures else "unknown"
status = "passed" if success else "blocked_desktop" if failure == "blockedDesktop" else "failed"
readback = fields.get("readback", "none")
if readback not in {"none", "changedAfterSettle", "unchanged", "partialPrefix", "extraSuffix", "differentText", "missingAXValue"}:
    readback = "unknown"
def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()
def command(*args):
    return subprocess.check_output(args, text=True).strip()
report = {
    "schemaVersion": 1,
    "syntheticOnly": True,
    "status": status,
    "failureReason": "none" if success else failure,
    "readbackDiagnostic": readback,
    "identityVerified": success,
    "exactInsertionObserved": success,
    "selectedTextVerified": success,
    "exactReplacementObserved": success,
    "macOSVersion": command("sw_vers", "-productVersion"),
    "textEditVersion": command("plutil", "-extract", "CFBundleShortVersionString", "raw", "-o", "-", "/System/Applications/TextEdit.app/Contents/Info.plist"),
    "textEditBuild": command("plutil", "-extract", "CFBundleVersion", "raw", "-o", "-", "/System/Applications/TextEdit.app/Contents/Info.plist"),
    "gitHead": command("git", "rev-parse", "HEAD"),
    "workingTreeDirty": bool(command("git", "status", "--porcelain")),
    "adapterSourceSHA256": sha("Cadence/Services/ScribeTextEditDocumentIdentityAdapter.swift"),
    "probeSourceSHA256": sha("tools/ComposeTextEditSurfaceProbe/main.swift"),
    "cadenceDebugLibrarySHA256": sha(library),
    "probeExecutableSHA256": sha(binary),
    "limitations": [
        "Development Debug module, not a signed Cadence candidate.",
        "One synthetic saved-document editor; no writing-model output or memory action.",
    ],
}
Path(report_path).write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
print(f"TextEdit synthetic identity/insertion: {report['status']} ({report['failureReason']})")
PY

"$root/scripts/verify_scribe_privacy_canaries.sh" "$evidence"
echo "Evidence: $report_path"
if [[ "$probe_status" -ne 0 || "$probe_output" != 'status=passed identity=true insertion=true exact_readback=true selection=true exact_replacement=true' ]]; then
  exit 1
fi
