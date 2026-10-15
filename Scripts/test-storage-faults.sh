#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/probe-common.sh
export DEVELOPER_DIR="${JHCUT_DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
compiler="$DEVELOPER_DIR/usr/bin/swiftc"; sdk="${JHCUT_SDK:-$DEVELOPER_DIR/SDKs/MacOSX26.5.sdk}"
"$compiler" -swift-version 5 -target "$(uname -m)-apple-macos14.0" -sdk "$sdk" -O -parse-as-library \
 -I "$build_dir" -L "$build_dir" -lJHCutCore -Xlinker -rpath -Xlinker @executable_path Tests/StorageFaultProbe.swift -o "$build_dir/StorageFaultProbe"
exec python3 Scripts/test-storage-faults.py --probe "$build_dir/StorageFaultProbe" --output "${1:-Artifacts/Runs/Storage-$(uuidgen)}"
