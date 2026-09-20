#!/bin/bash
set -euo pipefail
JHCUT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$JHCUT_ROOT"
export DEVELOPER_DIR="${JHCUT_DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
JHCUT_TOOLCHAIN="$DEVELOPER_DIR/usr/bin"
if [[ ! -x "$JHCUT_TOOLCHAIN/swiftc" ]]; then JHCUT_TOOLCHAIN="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin"; fi
JHCUT_SDK_PATH="${JHCUT_SDK:-$DEVELOPER_DIR/SDKs/MacOSX26.5.sdk}"
if [[ ! -d "$JHCUT_SDK_PATH" ]]; then JHCUT_SDK_PATH="$(xcrun --show-sdk-path)"; fi
mkdir -p Build/productivity
"$JHCUT_TOOLCHAIN/swiftc" -swift-version 5 -target "$(uname -m)-apple-macos14.0" -sdk "$JHCUT_SDK_PATH" -O -g -parse-as-library \
  Domain/*.swift MediaEngine/MediaImporter.swift MediaEngine/WaveformAnalyzer.swift Services/AudioAnalysis.swift Services/LocalTranscription.swift Tests/ProductivityProbe.swift -o Build/productivity/ProductivityProbe
exec Build/productivity/ProductivityProbe "${1:-$JHCUT_ROOT/Artifacts/Productivity-0.3}" "${@:2}"
