#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash Scripts/real-copies.sh copy
export DEVELOPER_DIR="${JHCUT_DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
compiler="$DEVELOPER_DIR/usr/bin/swiftc"; sdk="${JHCUT_SDK:-$DEVELOPER_DIR/SDKs/MacOSX26.5.sdk}"
"$compiler" -swift-version 5 -target "$(uname -m)-apple-macos14.0" -sdk "$sdk" -O -parse-as-library \
  -I Build -L Build -lJHCutCore -Xlinker -rpath -Xlinker @executable_path Tests/RealIPhone07Probe.swift -o Build/RealIPhone07Probe
Build/RealIPhone07Probe "${1:-Artifacts/Upgrade-0.7/RealIPhone}" "${@:2}"
bash Scripts/real-copies.sh verify
