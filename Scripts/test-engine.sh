#!/bin/bash
set -euo pipefail
JHCUT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$JHCUT_ROOT"
# The main build produces the exact core used by the editor. Set JHCUT_ENGINE_BUILD to an isolated core for development.
JHCUT_ENGINE_BUILD="${JHCUT_ENGINE_BUILD:-$JHCUT_ROOT/Build}"
if [[ ! -f "$JHCUT_ENGINE_BUILD/JHCutCore.swiftmodule" || ! -f "$JHCUT_ENGINE_BUILD/libJHCutCore.dylib" ]]; then
  if [[ "$JHCUT_ENGINE_BUILD" != "$JHCUT_ROOT/Build" ]]; then
    echo "Core module is missing in $JHCUT_ENGINE_BUILD. Build it before running this probe." >&2
    exit 1
  fi
  bash Scripts/build.sh
fi
export DEVELOPER_DIR="${JHCUT_DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
JHCUT_TOOLCHAIN="$DEVELOPER_DIR/usr/bin"
if [[ ! -x "$JHCUT_TOOLCHAIN/swiftc" ]]; then
  JHCUT_TOOLCHAIN="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin"
fi
JHCUT_TEST_SDK="${JHCUT_SDK:-$DEVELOPER_DIR/SDKs/MacOSX26.5.sdk}"
if [[ ! -d "$JHCUT_TEST_SDK" ]]; then JHCUT_TEST_SDK="$(xcrun --show-sdk-path)"; fi
JHCUT_ARCH="$(uname -m)"
if [[ $# -gt 0 ]]; then
  JHCUT_OUTPUT="$1"
else
  mkdir -p "$JHCUT_ROOT/Artifacts"
  JHCUT_OUTPUT="$(mktemp -d "$JHCUT_ROOT/Artifacts/EngineProbe-XXXXXX")"
fi
# Only the selected fixture/output directory is populated. Use a new directory to preserve previous evidence.
"$JHCUT_TOOLCHAIN/swiftc" -swift-version 5 -target "$JHCUT_ARCH-apple-macos14.0" -sdk "$JHCUT_TEST_SDK" -O -g \
  -parse-as-library -I "$JHCUT_ENGINE_BUILD" -L "$JHCUT_ENGINE_BUILD" -lJHCutCore \
  -Xlinker -rpath -Xlinker @executable_path \
  Validation/Fixtures.swift Validation/MediaInspection.swift Tests/EngineProbe.swift \
  -o "$JHCUT_ENGINE_BUILD/EngineProbe"
exec "$JHCUT_ENGINE_BUILD/EngineProbe" "$JHCUT_OUTPUT"
