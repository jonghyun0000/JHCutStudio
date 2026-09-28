#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Process-local toolchain selection. Does not change xcode-select or accept licenses.
export DEVELOPER_DIR="${JHCUT_DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
toolchain="$DEVELOPER_DIR/usr/bin"
if [[ ! -x "$toolchain/swiftc" ]]; then
  toolchain="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin"
fi
sdk="${JHCUT_SDK:-$DEVELOPER_DIR/SDKs/MacOSX26.5.sdk}"
if [[ ! -d "$sdk" ]]; then sdk="$(xcrun --show-sdk-path)"; fi
arch="$(uname -m)"
build_dir="${JHCUT_BUILD_DIR:-Build}"
mkdir -p "$build_dir"
flags=(-swift-version 5 -target "$arch-apple-macos14.0" -sdk "$sdk" -O -g)
core=(Domain/*.swift Persistence/*.swift MediaEngine/*.swift)
if compgen -G 'Services/*.swift' > /dev/null; then core+=(Services/*.swift); fi
echo "Building core with $toolchain/swiftc and $sdk"
"$toolchain/swiftc" "${flags[@]}" -emit-library -emit-module -enable-testing -module-name JHCutCore \
  -emit-module-path "$build_dir/JHCutCore.swiftmodule" -Xlinker -install_name -Xlinker @rpath/libJHCutCore.dylib \
  "${core[@]}" -o "$build_dir/libJHCutCore.dylib"

echo "Built core $build_dir/libJHCutCore.dylib"
