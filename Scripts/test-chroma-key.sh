#!/bin/bash
set -euo pipefail
JHCUT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$JHCUT_ROOT"
source Scripts/probe-common.sh
# The main build produces the exact core used by the editor. Set JHCUT_CHROMA_BUILD to an isolated core for development.
JHCUT_CHROMA_BUILD="${JHCUT_CHROMA_BUILD:-$build_dir}"
if [[ ! -f "$JHCUT_CHROMA_BUILD/JHCutCore.swiftmodule" || ! -f "$JHCUT_CHROMA_BUILD/libJHCutCore.dylib" ]]; then
  if [[ "$JHCUT_CHROMA_BUILD" != "$JHCUT_ROOT/Build" ]]; then
    echo "Core module is missing in $JHCUT_CHROMA_BUILD. Build it before running this probe." >&2
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
  JHCUT_OUTPUT="$(mktemp -d "$JHCUT_ROOT/Artifacts/ChromaKeyProbe-XXXXXX")"
fi
# Only the selected fixture/output directory is populated. Use a new directory to preserve previous evidence.
"$JHCUT_TOOLCHAIN/swiftc" -swift-version 5 -target "$JHCUT_ARCH-apple-macos14.0" -sdk "$JHCUT_TEST_SDK" -O -g \
  -parse-as-library -I "$JHCUT_CHROMA_BUILD" -L "$JHCUT_CHROMA_BUILD" -lJHCutCore \
  -Xlinker -rpath -Xlinker @executable_path \
  Validation/Fixtures.swift Validation/MediaInspection.swift Tests/ProbeWorkspace.swift Tests/ChromaKeyProbe.swift \
  -o "$JHCUT_CHROMA_BUILD/ChromaKeyProbe"
exec "$JHCUT_CHROMA_BUILD/ChromaKeyProbe" "$JHCUT_OUTPUT"
