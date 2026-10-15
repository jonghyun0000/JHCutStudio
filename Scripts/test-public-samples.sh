#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/probe-common.sh
# The verification runner creates its suite output parent before this script.
# Generation is deliberately a NEW child so no previous samples are overwritten.
output_parent="${1:-Artifacts/PublicSamples}"
mkdir -p "$output_parent"
output_parent="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).resolve())' "$output_parent")"
if [[ -e "$output_parent/Generation" || -e "$output_parent/source-provenance.json" ]]; then
  echo "Refusing existing public-sample generation/provenance" >&2; exit 1
fi
export DEVELOPER_DIR="${JHCUT_DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
compiler="$DEVELOPER_DIR/usr/bin/swiftc"
if [[ ! -x "$compiler" ]]; then compiler="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"; fi
sdk="${JHCUT_SDK:-$DEVELOPER_DIR/SDKs/MacOSX26.5.sdk}"
if [[ ! -d "$sdk" ]]; then sdk="$(xcrun --sdk macosx --show-sdk-path)"; fi
python3 -B Scripts/package-public-samples.py capture --repo "$PWD" \
  --core "$build_dir/libJHCutCore.dylib" --output "$output_parent/source-provenance.json"
"$compiler" -swift-version 5 -target "$(uname -m)-apple-macos14.0" -sdk "$sdk" -O -parse-as-library \
  -I "$build_dir" -L "$build_dir" -lJHCutCore -Xlinker -rpath -Xlinker @executable_path \
  App/EditorModel.swift App/EditorProductivity.swift App/EditorWorkflow.swift App/EditorQuality.swift \
  App/EditorTransitions.swift App/EditorSpeedTools.swift App/EditorGeneratedMedia.swift \
  Validation/Fixtures.swift Validation/MediaInspection.swift Tests/PublicSamplesProbe.swift \
  -o "$build_dir/PublicSamplesProbe"
"$build_dir/PublicSamplesProbe" "$output_parent/Generation"
python3 -B Scripts/package-public-samples.py package --repo "$PWD" \
  --provenance "$output_parent/source-provenance.json" --generation "$output_parent/Generation" \
  --binary "$build_dir/PublicSamplesProbe" --output-parent "$output_parent"
