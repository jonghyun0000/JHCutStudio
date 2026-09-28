#!/bin/bash
# Accuracy on real iPhone video COPIES against a human transcript.
# Usage: Scripts/test-real-accuracy.sh [IMG_xxxx.mov:start:end ...]
set -euo pipefail
cd "$(dirname "$0")/.."
bash Scripts/real-copies.sh copy
export DEVELOPER_DIR="${JHCUT_DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
compiler="$DEVELOPER_DIR/usr/bin/swiftc"; sdk="${JHCUT_SDK:-$DEVELOPER_DIR/SDKs/MacOSX26.5.sdk}"
"$compiler" -swift-version 5 -target "$(uname -m)-apple-macos14.0" -sdk "$sdk" -O -parse-as-library \
  -I Build -L Build -lJHCutCore -Xlinker -rpath -Xlinker @executable_path Tests/RealAccuracyProbe.swift -o Build/RealAccuracyProbe
Build/RealAccuracyProbe "${JHCUT_ACCURACY_DIR:-Artifacts/Upgrade-0.7/Accuracy}" "$@"
bash Scripts/real-copies.sh verify
