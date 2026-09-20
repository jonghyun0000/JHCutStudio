#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${JHCUT_DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
toolchain="$DEVELOPER_DIR/usr/bin"
if [[ ! -x "$toolchain/swiftc" ]]; then toolchain="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin"; fi
sdk="${JHCUT_SDK:-$DEVELOPER_DIR/SDKs/MacOSX26.5.sdk}"
if [[ ! -d "$sdk" ]]; then sdk="$(xcrun --show-sdk-path)"; fi
build="${JHCUT_COMPAT_BUILD:-$PWD/Build/engine-compat}"
mkdir -p "$build" Artifacts
output="${1:-$(mktemp -d "$PWD/Artifacts/Compatibility-XXXXXX")}"
mkdir -p "$output"
flags=(-swift-version 5 -target "$(uname -m)-apple-macos14.0" -sdk "$sdk" -O)
if [[ "${JHCUT_COMPAT_USE_EXISTING_CORE:-0}" != "1" ]]; then
"$toolchain/swiftc" "${flags[@]}" -emit-library -emit-module -enable-testing -module-name JHCutCore \
  -emit-module-path "$build/JHCutCore.swiftmodule" -Xlinker -install_name -Xlinker @rpath/libJHCutCore.dylib \
  Domain/*.swift Persistence/*.swift MediaEngine/*.swift Services/*.swift -o "$build/libJHCutCore.dylib"
fi
"$toolchain/swiftc" "${flags[@]}" -parse-as-library -I "$build" -L "$build" -lJHCutCore \
  -Xlinker -rpath -Xlinker @executable_path Tests/CompatibilityProbe.swift Validation/Fixtures.swift Validation/MediaInspection.swift -o "$build/CompatibilityProbe"
"$build/CompatibilityProbe" "$output"
echo "Evidence: $output/report.md"
