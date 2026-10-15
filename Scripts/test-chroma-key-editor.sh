#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/probe-common.sh
export DEVELOPER_DIR="${JHCUT_DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
compiler="$DEVELOPER_DIR/usr/bin/swiftc"
if [[ ! -x "$compiler" ]]; then compiler="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"; fi
sdk="${JHCUT_SDK:-$DEVELOPER_DIR/SDKs/MacOSX26.5.sdk}"
if [[ ! -d "$sdk" ]]; then sdk="$(xcrun --show-sdk-path)"; fi
"$compiler" -swift-version 5 -target "$(uname -m)-apple-macos14.0" -sdk "$sdk" -O -parse-as-library \
  -I "$build_dir" -L "$build_dir" -lJHCutCore -Xlinker -rpath -Xlinker @executable_path App/EditorModel.swift App/EditorProductivity.swift App/EditorWorkflow.swift App/EditorQuality.swift App/EditorTransitions.swift App/EditorSpeedTools.swift App/EditorGeneratedMedia.swift App/ChromaColorConversion.swift Tests/ProbeWorkspace.swift Tests/ChromaKeyEditorProbe.swift -o "$build_dir/ChromaKeyEditorProbe"
"$build_dir/ChromaKeyEditorProbe" "${1:-Artifacts/ChromaKeyEditorProbe}"
