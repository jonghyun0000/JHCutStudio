#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${JHCUT_DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
sdk="${JHCUT_SDK:-$DEVELOPER_DIR/SDKs/MacOSX26.5.sdk}"
compiler="$DEVELOPER_DIR/usr/bin/swiftc"
if [[ ! -x "$compiler" ]]; then compiler="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"; fi
bash Scripts/real-copies.sh copy
out="${1:-Artifacts/Multilingual-0.6/RealIPhone}"
mkdir -p "$out"
"$compiler" -swift-version 5 -target "$(uname -m)-apple-macos14.0" -sdk "$sdk" -O -parse-as-library \
  -I Build -L Build -lJHCutCore -Xlinker -rpath -Xlinker @executable_path \
  Tests/RealSpeech05Probe.swift -o Build/RealIPhoneProbe
exec Build/RealIPhoneProbe "$out"
