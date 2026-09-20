#!/bin/bash
set -euo pipefail
JHCUT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$JHCUT_ROOT"
# Set JHCUT_FORMAT_BUILD to an isolated core to compare two engine revisions with one probe.
JHCUT_FORMAT_BUILD="${JHCUT_FORMAT_BUILD:-$JHCUT_ROOT/Build}"
if [[ ! -f "$JHCUT_FORMAT_BUILD/JHCutCore.swiftmodule" || ! -f "$JHCUT_FORMAT_BUILD/libJHCutCore.dylib" ]]; then
  echo "Core module is missing in $JHCUT_FORMAT_BUILD." >&2; exit 1
fi
export DEVELOPER_DIR="${JHCUT_DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
JHCUT_TOOLCHAIN="$DEVELOPER_DIR/usr/bin"
if [[ ! -x "$JHCUT_TOOLCHAIN/swiftc" ]]; then JHCUT_TOOLCHAIN="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin"; fi
JHCUT_TEST_SDK="${JHCUT_SDK:-$DEVELOPER_DIR/SDKs/MacOSX26.5.sdk}"
if [[ ! -d "$JHCUT_TEST_SDK" ]]; then JHCUT_TEST_SDK="$(xcrun --show-sdk-path)"; fi
"$JHCUT_TOOLCHAIN/swiftc" -swift-version 5 -target "$(uname -m)-apple-macos14.0" -sdk "$JHCUT_TEST_SDK" -O -g \
  -parse-as-library -I "$JHCUT_FORMAT_BUILD" -L "$JHCUT_FORMAT_BUILD" -lJHCutCore \
  -Xlinker -rpath -Xlinker @executable_path \
  Validation/Fixtures.swift Validation/MediaInspection.swift Tests/FormatProbe.swift \
  -o "$JHCUT_FORMAT_BUILD/FormatProbe"
exec "$JHCUT_FORMAT_BUILD/FormatProbe" "${1:-$JHCUT_ROOT/Artifacts/Format}" 
