#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
"$DEVELOPER_DIR/usr/bin/swiftc" -swift-version 5 -target "$(uname -m)-apple-macos14.0" -sdk "$DEVELOPER_DIR/SDKs/MacOSX26.5.sdk" -O -parse-as-library -I Build -L Build -lJHCutCore -Xlinker -rpath -Xlinker @executable_path Tests/ConnectedEditingProbe.swift -o Build/ConnectedEditingProbe
Build/ConnectedEditingProbe "${1:-Artifacts/Upgrade-0.5/Connected}"
