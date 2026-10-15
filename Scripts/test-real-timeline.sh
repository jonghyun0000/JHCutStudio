#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/probe-common.sh
export DEVELOPER_DIR="${JHCUT_DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
"$DEVELOPER_DIR/usr/bin/swiftc" -swift-version 5 -target "$(uname -m)-apple-macos14.0" -sdk "${JHCUT_SDK:-$DEVELOPER_DIR/SDKs/MacOSX26.5.sdk}" -O -g -parse-as-library -D REAL_TIMELINE_PROBE -I "$build_dir" -L "$build_dir" -lJHCutCore -Xlinker -rpath -Xlinker @executable_path App/EditorModel.swift App/EditorProductivity.swift App/EditorWorkflow.swift App/EditorQuality.swift Validation/Fixtures.swift Validation/MediaInspection.swift Tests/ProbeWorkspace.swift Tests/RealTimelineProbe.swift -o "$build_dir/RealTimelineProbe"
exec "$build_dir/RealTimelineProbe" "$@"
