#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
compiler="$DEVELOPER_DIR/usr/bin/swiftc"
flags=(-swift-version 5 -target "$(uname -m)-apple-macos14.0" -sdk "$DEVELOPER_DIR/SDKs/MacOSX26.5.sdk" -O -parse-as-library -I Build -L Build -lJHCutCore -Xlinker -rpath -Xlinker @executable_path)
# Requires the approved base model and the existing Korean speech fixture from the caption suite.
"$compiler" "${flags[@]}" App/EditorModel.swift App/EditorProductivity.swift App/EditorWorkflow.swift Tests/Workflow05Probe.swift -o Build/Workflow05Probe
Build/Workflow05Probe
for probe in MediaSafety05Probe Limiter05Probe; do
  "$compiler" "${flags[@]}" "Tests/$probe.swift" -o "Build/$probe"
  "Build/$probe"
done
