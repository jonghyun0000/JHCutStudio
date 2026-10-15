#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/probe-common.sh
export DEVELOPER_DIR="${JHCUT_DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
gui_dir="${1:?Pass a new Artifacts GUI directory}"
fixture="${2:?Pass an owned fixture project}"
python3 - "$gui_dir" "$fixture" <<'PY'
from pathlib import Path
import sys
root=(Path.cwd()/'Artifacts').resolve(); output=Path(sys.argv[1]).absolute(); fixture=Path(sys.argv[2]).resolve()
assert output.resolve().is_relative_to(root) and not output.exists()
assert fixture.is_relative_to(root) and fixture.is_file()
output.mkdir(parents=True)
PY
bundle="$gui_dir/JH CUT Playback QA.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Frameworks" "$bundle/Contents/Resources"
sources=()
for source in App/*.swift; do [[ "$source" == 'App/JHCutStudioApp.swift' ]] || sources+=("$source"); done
"$DEVELOPER_DIR/usr/bin/swiftc" -swift-version 5 -target "$(uname -m)-apple-macos14.0" -sdk "${JHCUT_SDK:-$DEVELOPER_DIR/SDKs/MacOSX26.5.sdk}" -O -parse-as-library -D PLAYBACK_GUI_PROBE -I "$build_dir" -L "$build_dir" -lJHCutCore -Xlinker -rpath -Xlinker @executable_path/../Frameworks "${sources[@]}" Tests/PlaybackGUIApp.swift -o "$bundle/Contents/MacOS/PlaybackQA"
cp "$build_dir/libJHCutCore.dylib" "$bundle/Contents/Frameworks/"
rsync -a Resources/Library/ "$bundle/Contents/Resources/Library/"
python3 - "$bundle" "$gui_dir" "$fixture" <<'PY'
import plistlib,json,sys,hashlib
from pathlib import Path
bundle=Path(sys.argv[1]); root=Path(sys.argv[2]).resolve(); fixture=Path(sys.argv[3]).resolve()
(bundle/'Contents/Info.plist').write_bytes(plistlib.dumps(dict(JHCutQARoot=str(root),JHCutQAProject=str(fixture),CFBundleExecutable='PlaybackQA',CFBundleIdentifier='studio.jhcut.playbackqa.'+hashlib.sha256(str(root).encode()).hexdigest()[:12],CFBundleName='JH CUT Playback QA',CFBundlePackageType='APPL',CFBundleVersion='1',LSMinimumSystemVersion='14.0',NSPrincipalClass='NSApplication',NSHighResolutionCapable=True)))
(root/'input-receipt.json').write_text(json.dumps(dict(fixture=str(fixture),sha256=hashlib.sha256(fixture.read_bytes()).hexdigest()),indent=2)+'\n')
PY
codesign --force --sign - "$bundle/Contents/Frameworks/libJHCutCore.dylib"
codesign --force --sign - "$bundle"
