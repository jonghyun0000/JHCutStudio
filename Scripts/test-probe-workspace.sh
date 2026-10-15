#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/probe-common.sh
export DEVELOPER_DIR="${JHCUT_DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
toolchain="$DEVELOPER_DIR/usr/bin"
if [[ ! -x "$toolchain/swiftc" ]]; then
  toolchain="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin"
fi
sdk="${JHCUT_SDK:-$DEVELOPER_DIR/SDKs/MacOSX26.5.sdk}"
if [[ ! -d "$sdk" ]]; then sdk="$(xcrun --sdk macosx --show-sdk-path)"; fi
"$toolchain/swiftc" -swift-version 5 -target "$(uname -m)-apple-macos14.0" -sdk "$sdk" -parse-as-library Tests/ProbeWorkspace.swift Tests/ProbeWorkspaceProbe.swift -o "$build_dir/ProbeWorkspaceProbe"
"$build_dir/ProbeWorkspaceProbe"
