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
echo "Building editor and validation tool"
"$toolchain/swiftc" "${flags[@]}" -parse-as-library -I "$build_dir" -L "$build_dir" -lJHCutCore \
  -Xlinker -rpath -Xlinker @executable_path -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  App/*.swift -o "$build_dir/JHCutStudio"
"$toolchain/swiftc" "${flags[@]}" -parse-as-library -I "$build_dir" -L "$build_dir" -lJHCutCore \
  -Xlinker -rpath -Xlinker @executable_path Validation/*.swift -o "$build_dir/JHCutValidate"
bundle="$build_dir/JH CUT Studio.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Frameworks" "$bundle/Contents/Resources"
cp "$build_dir/JHCutStudio" "$bundle/Contents/MacOS/JHCutStudio"
cp "$build_dir/libJHCutCore.dylib" "$bundle/Contents/Frameworks/"
cp Resources/Info.plist "$bundle/Contents/Info.plist"
bash Scripts/build-icon.sh
cp Resources/JHCutStudio.icns "$bundle/Contents/Resources/"
if [[ -f Resources/Library/manifest.json ]]; then
  mkdir -p "$bundle/Contents/Resources/Library"
  rsync -a --delete Resources/Library/ "$bundle/Contents/Resources/Library/"
fi
if [[ -f Resources/Whisper/whisper-cli ]]; then
  mkdir -p "$bundle/Contents/Resources/Whisper"
  rsync -a --delete Resources/Whisper/ "$bundle/Contents/Resources/Whisper/"
  codesign --force --sign - "$bundle/Contents/Resources/Whisper/whisper-cli"
fi
codesign --force --sign - "$bundle/Contents/Frameworks/libJHCutCore.dylib"
codesign --force --sign - "$bundle"
touch "$bundle"
echo "Built $PWD/$bundle (local ad-hoc signature; not notarized)"
