#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
bundle='Artifacts/Playback-Library/JH CUT Playback QA.app'
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Frameworks" "$bundle/Contents/Resources"
sources=()
for source in App/*.swift; do [[ "$source" == 'App/JHCutStudioApp.swift' ]] || sources+=("$source"); done
"$DEVELOPER_DIR/usr/bin/swiftc" -swift-version 5 -target "$(uname -m)-apple-macos14.0" -sdk "$DEVELOPER_DIR/SDKs/MacOSX26.5.sdk" -O -parse-as-library -D PLAYBACK_GUI_PROBE -I Build -L Build -lJHCutCore -Xlinker -rpath -Xlinker @executable_path/../Frameworks "${sources[@]}" Tests/PlaybackGUIApp.swift -o "$bundle/Contents/MacOS/PlaybackQA"
cp Build/libJHCutCore.dylib "$bundle/Contents/Frameworks/"
rsync -a Resources/Library/ "$bundle/Contents/Resources/Library/"
python3 - <<'PY'
import plistlib
from pathlib import Path
p=Path('Artifacts/Playback-Library/JH CUT Playback QA.app/Contents/Info.plist')
p.write_bytes(plistlib.dumps(dict(CFBundleExecutable='PlaybackQA',CFBundleIdentifier='studio.jhcut.playbackqa',CFBundleName='JH CUT Playback QA',CFBundlePackageType='APPL',CFBundleVersion='1',LSMinimumSystemVersion='14.0',NSPrincipalClass='NSApplication',NSHighResolutionCapable=True)))
PY
codesign --force --sign - "$bundle/Contents/Frameworks/libJHCutCore.dylib"
codesign --force --sign - "$bundle"
