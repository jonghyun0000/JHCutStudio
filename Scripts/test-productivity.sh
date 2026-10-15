#!/bin/bash
set -euo pipefail
JHCUT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$JHCUT_ROOT"
source Scripts/probe-common.sh
export DEVELOPER_DIR="${JHCUT_DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
JHCUT_TOOLCHAIN="$DEVELOPER_DIR/usr/bin"
if [[ ! -x "$JHCUT_TOOLCHAIN/swiftc" ]]; then JHCUT_TOOLCHAIN="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin"; fi
JHCUT_SDK_PATH="${JHCUT_SDK:-$DEVELOPER_DIR/SDKs/MacOSX26.5.sdk}"
if [[ ! -d "$JHCUT_SDK_PATH" ]]; then JHCUT_SDK_PATH="$(xcrun --show-sdk-path)"; fi
mkdir -p "$build_dir/productivity"
"$JHCUT_TOOLCHAIN/swiftc" -swift-version 5 -target "$(uname -m)-apple-macos14.0" -sdk "$JHCUT_SDK_PATH" -O -g -parse-as-library \
  -I "$build_dir" -L "$build_dir" -lJHCutCore -Xlinker -rpath -Xlinker "$build_dir" Tests/ProbeWorkspace.swift Tests/ProductivityProbe.swift -o "$build_dir/productivity/ProductivityProbe"
exec "$build_dir/productivity/ProductivityProbe" "${1:-$JHCUT_ROOT/Artifacts/Productivity-0.3}" "${@:2}"
