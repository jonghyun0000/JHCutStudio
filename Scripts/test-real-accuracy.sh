#!/bin/bash
# Fresh real iPhone preparation/scoring. Human references are read-only inputs.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${JHCUT_BUILD_DIR:-}" ]]; then
  standalone="$PWD/Artifacts/Runs/AccuracyStandalone-$(date +%Y%m%d-%H%M%S)-$(uuidgen)"
  export JHCUT_BUILD_DIR="$standalone/Build"
fi
source Scripts/probe-common.sh
if [[ "${JHCUT_USE_EXISTING_CORE:-0}" != 1 ]]; then bash Scripts/build-core.sh; fi
export JHCUT_REAL_COPY_REUSE="${JHCUT_REAL_COPY_REUSE:-1}"
export JHCUT_REAL_COPY_REPORT_DIR="${JHCUT_REAL_COPY_REPORT_DIR:-$(dirname "$build_dir")/DatasetVerification/real-accuracy}"
bash Scripts/real-copies.sh copy
trap 'probe_exit=$?; trap - EXIT; bash Scripts/real-copies.sh verify || exit 1; exit "$probe_exit"' EXIT
export DEVELOPER_DIR="${JHCUT_DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
compiler="$DEVELOPER_DIR/usr/bin/swiftc"; sdk="${JHCUT_SDK:-$DEVELOPER_DIR/SDKs/MacOSX26.5.sdk}"
"$compiler" -swift-version 5 -target "$(uname -m)-apple-macos14.0" -sdk "$sdk" -O -parse-as-library \
  -I "$build_dir" -L "$build_dir" -lJHCutCore -Xlinker -rpath -Xlinker @executable_path \
  Tests/ProbeWorkspace.swift Tests/AccuracyRunSupport.swift Tests/AccuracyRunProgress.swift Tests/RealAccuracyProbe.swift -o "$build_dir/RealAccuracyProbe"
run_log="$build_dir/accuracy-run-$(uuidgen).log"
"$build_dir/RealAccuracyProbe" "$@" | tee "$run_log"
output="$(sed -n 's/^ACCURACY_OUTPUT=//p' "$run_log")"
python3 Scripts/build-accuracy-review.py "$output"
