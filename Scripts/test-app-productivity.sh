#!/bin/bash
set -euo pipefail
JHCUT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$JHCUT_ROOT"
export DEVELOPER_DIR="${JHCUT_DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
JHCUT_TOOLCHAIN="$DEVELOPER_DIR/usr/bin"
if [[ ! -x "$JHCUT_TOOLCHAIN/swiftc" ]]; then JHCUT_TOOLCHAIN="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin"; fi
JHCUT_SDK_PATH="${JHCUT_SDK:-$DEVELOPER_DIR/SDKs/MacOSX26.5.sdk}"
if [[ ! -d "$JHCUT_SDK_PATH" ]]; then JHCUT_SDK_PATH="$(xcrun --show-sdk-path)"; fi
"$JHCUT_TOOLCHAIN/swiftc" -swift-version 5 -target "$(uname -m)-apple-macos14.0" -sdk "$JHCUT_SDK_PATH" -O -g -parse-as-library -D PRODUCTIVITY_APP_PROBE \
  -I Build -L Build -lJHCutCore -Xlinker -rpath -Xlinker @executable_path \
  App/EditorModel.swift App/EditorProductivity.swift App/EditorWorkflow.swift Tests/EditorProductivityProbe.swift -o Build/EditorProductivityProbe
exec Build/EditorProductivityProbe "${1:-$JHCUT_ROOT/Artifacts/Productivity-App-0.3}"
