#!/bin/bash
# Runs every automated suite touched by the 0.7 upgrades and prints one summary line per suite.
# Core library must be built first (Scripts/build-core.sh or Scripts/build.sh).
set -uo pipefail
cd "$(dirname "$0")/.."
logs="${JHCUT_TEST_LOGS:-Artifacts/Upgrade-0.7/TestLogs}"
mkdir -p "$logs"
suites=(${JHCUT_SUITES:-domain compatibility connected productivity auto-captions multilingual checkpoint evaluation language speaker batch glossary vad quality distribution stabilization stabilize-editor})
failed=0
for suite in "${suites[@]}"; do
  start=$(date +%s)
  bash "Scripts/test-$suite.sh" > "$logs/$suite.log" 2>&1; status=$?
  pass=$(grep -c '^PASS' "$logs/$suite.log"); fail=$(grep -c '^FAIL' "$logs/$suite.log")
  summary=$(grep -E '_RESULT|COMPATIBILITY_RESULT|Executed [0-9]+ tests' "$logs/$suite.log" | tail -1)
  printf '%-14s exit=%d pass=%d fail=%d %ss  %s\n' "$suite" "$status" "$pass" "$fail" "$(( $(date +%s) - start ))" "$summary"
  [[ $status -ne 0 || $fail -ne 0 ]] && failed=$((failed + 1))
done
echo "UPGRADE07_SUITES suites=${#suites[@]} failed=$failed"
exit $failed
