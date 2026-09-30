#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${JHCUT_DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
compiler="$DEVELOPER_DIR/usr/bin/swiftc"; sdk="${JHCUT_SDK:-$DEVELOPER_DIR/SDKs/MacOSX26.5.sdk}"
"$compiler" -swift-version 5 -target "$(uname -m)-apple-macos14.0" -sdk "$sdk" -O -parse-as-library \
  -I Build -L Build -lJHCutCore -Xlinker -rpath -Xlinker @executable_path Tests/TransitionProbe.swift -o Build/TransitionProbe
bash Scripts/real-copies.sh copy
Build/TransitionProbe "${1:-Artifacts/Upgrade-0.7/Transitions}"
bash Scripts/real-copies.sh verify > /dev/null && echo "ORIGINALS_UNCHANGED"
