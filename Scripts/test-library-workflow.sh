#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/probe-common.sh
export DEVELOPER_DIR="${JHCUT_DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
"$DEVELOPER_DIR/usr/bin/swiftc" -swift-version 5 -target "$(uname -m)-apple-macos14.0" -sdk "${JHCUT_SDK:-$DEVELOPER_DIR/SDKs/MacOSX26.5.sdk}" -O -parse-as-library -I "$build_dir" -L "$build_dir" -lJHCutCore -Xlinker -rpath -Xlinker @executable_path App/EditorModel.swift App/EditorProductivity.swift App/EditorWorkflow.swift App/EditorQuality.swift App/EditorTransitions.swift App/EditorSpeedTools.swift App/EditorGeneratedMedia.swift Validation/Fixtures.swift Validation/MediaInspection.swift Tests/ProbeWorkspace.swift Tests/LibraryWorkflowProbe.swift -o "$build_dir/LibraryWorkflowProbe"
exec "$build_dir/LibraryWorkflowProbe" "$@"
