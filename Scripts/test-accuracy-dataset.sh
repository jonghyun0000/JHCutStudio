#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/probe-common.sh
export DEVELOPER_DIR="${JHCUT_DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
compiler="$DEVELOPER_DIR/usr/bin/swiftc"; sdk="${JHCUT_SDK:-$DEVELOPER_DIR/SDKs/MacOSX26.5.sdk}"
"$compiler" -swift-version 5 -target "$(uname -m)-apple-macos14.0" -sdk "$sdk" -O -parse-as-library \
  -I "$build_dir" -L "$build_dir" -lJHCutCore -Xlinker -rpath -Xlinker @executable_path \
  Tests/ProbeWorkspace.swift Tests/AccuracyRunSupport.swift Tests/AccuracyDatasetProbe.swift -o "$build_dir/AccuracyDatasetProbe"
output="${1:?Supply a fresh output directory}"
"$build_dir/AccuracyDatasetProbe" "$output"
node Tests/AccuracyReviewTests.js "$output"
"$build_dir/AccuracyDatasetProbe" --verify-js-export "$output/js-human-fixture.json"
python3 - "$output" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]);rows=json.loads((p/'core-checks.json').read_text())+json.loads((p/'js-checks.json').read_text())
rows.append({'name':'JavaScript export validates through Swift provenance gate','passed':True})
(p/'checks.json').write_text(json.dumps(rows,indent=2)+'\n')
f=sum(not r['passed'] for r in rows);print(f'ACCURACY_DATASET_RESULT checks={len(rows)} failures={f}')
if f:sys.exit(1)
PY
