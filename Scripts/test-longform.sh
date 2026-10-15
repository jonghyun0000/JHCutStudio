#!/bin/bash
# Long-form measurements. Usage: Scripts/test-longform.sh [minutes...] (default: 30 60 120), plus a
# 30-minute run without skipping and a 60-minute cancel/resume run. Each run is its own process.
set -uo pipefail
cd "$(dirname "$0")/.."
bash Scripts/real-copies.sh copy
export DEVELOPER_DIR="${JHCUT_DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
compiler="$DEVELOPER_DIR/usr/bin/swiftc"; sdk="${JHCUT_SDK:-$DEVELOPER_DIR/SDKs/MacOSX26.5.sdk}"
"$compiler" -swift-version 5 -target "$(uname -m)-apple-macos14.0" -sdk "$sdk" -O -parse-as-library \
  -I Build -L Build -lJHCutCore -Xlinker -rpath -Xlinker @executable_path \
  App/EditorModel.swift App/EditorProductivity.swift App/EditorWorkflow.swift App/EditorQuality.swift Tests/LongFormProbe.swift -o Build/LongFormProbe || exit 1
out="${JHCUT_LONGFORM_DIR:-Artifacts/Upgrade-0.7/LongForm}"
runs=("${@}"); [[ ${#runs[@]} -eq 0 ]] && runs=("30 vad" "30 full" "60 vad" "120 vad" "60 cancel")
failed=0
for run in "${runs[@]}"; do
  set -- $run
  Build/LongFormProbe "$out" "$1" "${2:-vad}" || failed=$((failed + 1))
done
bash Scripts/real-copies.sh verify || failed=$((failed + 1))
echo "LONGFORM_RUNS failed=$failed"
exit $failed
