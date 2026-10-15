#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/probe-common.sh
export DEVELOPER_DIR="${JHCUT_DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
compiler="$DEVELOPER_DIR/usr/bin/swiftc"; sdk="${JHCUT_SDK:-$DEVELOPER_DIR/SDKs/MacOSX26.5.sdk}"
"$compiler" -swift-version 5 -target "$(uname -m)-apple-macos14.0" -sdk "$sdk" -O -parse-as-library -D PRODUCTIVITY_APP_PROBE \
 -I "$build_dir" -L "$build_dir" -lJHCutCore -Xlinker -rpath -Xlinker @executable_path \
 App/EditorModel.swift App/EditorProductivity.swift App/EditorWorkflow.swift App/EditorQuality.swift App/EditorTransitions.swift App/EditorSpeedTools.swift \
 Tests/ProbeWorkspace.swift Tests/EditorProductivityProbe.swift -o "$build_dir/EditorProductivityProbe"
exec "$build_dir/EditorProductivityProbe" "${1:-Artifacts/EditorProductivity}"
