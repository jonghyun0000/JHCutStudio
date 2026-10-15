#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/probe-common.sh
export DEVELOPER_DIR="${JHCUT_DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
gui_dir="${1:?Pass a fresh GUI output directory inside Artifacts}"
fixture="${2:?Pass a disposable fixture project inside Artifacts}"
python3 - "$gui_dir" <<'PY'
import sys
from pathlib import Path
root=(Path.cwd()/'Artifacts').resolve(); p=Path(sys.argv[1]).absolute()
assert p.resolve().is_relative_to(root), 'GUI output must be inside Artifacts'
assert not p.exists(), 'GUI output must be new; frozen evidence cannot be replaced'
p.mkdir(parents=True)
PY
bundle="$gui_dir/JH CUT Caption Workflow QA.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Frameworks" "$bundle/Contents/Resources"
sources=()
for source in App/*.swift; do [[ "$source" == 'App/JHCutStudioApp.swift' ]] || sources+=("$source"); done
"$DEVELOPER_DIR/usr/bin/swiftc" -swift-version 5 -target "$(uname -m)-apple-macos14.0" -sdk "${JHCUT_SDK:-$DEVELOPER_DIR/SDKs/MacOSX26.5.sdk}" -O -parse-as-library -D CAPTION_WORKFLOW_GUI \
  -I "$build_dir" -L "$build_dir" -lJHCutCore -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  "${sources[@]}" Tests/CaptionWorkflowGUIApp.swift -o "$bundle/Contents/MacOS/CaptionWorkflowQA"
cp "$build_dir/libJHCutCore.dylib" "$bundle/Contents/Frameworks/"
python3 - "$bundle" "$gui_dir" "$fixture" <<'PY'
import plistlib,sys,hashlib,tempfile,shutil,json
from pathlib import Path
p=Path(sys.argv[1])/'Contents/Info.plist'
root=Path(sys.argv[2]).resolve(); fixture=Path(sys.argv[3]).resolve()
assert fixture.is_relative_to((Path.cwd()/'Artifacts').resolve()) and fixture.is_file()
# Keep synthetic runtime data local: opening a T7 document programmatically can wait
# for removable-volume access. The QA app never needs blanket access to that volume.
runtime=Path(tempfile.mkdtemp(prefix='jhcut-caption-gui-'))
project=runtime/'project.jhcut'; shutil.copy2(fixture,project)
(root/'runtime-receipt.json').write_text(json.dumps(dict(runtime=str(runtime),project=str(project),input=str(fixture),inputSHA256=hashlib.sha256(fixture.read_bytes()).hexdigest()),indent=2))
p.write_bytes(plistlib.dumps(dict(JHCutQARoot=str(runtime),JHCutQAProject=str(project),CFBundleExecutable='CaptionWorkflowQA',CFBundleIdentifier='studio.jhcut.captionworkflowqa.'+hashlib.sha256(str(root).encode()).hexdigest()[:12],CFBundleName='JH CUT Caption Workflow QA',CFBundlePackageType='APPL',CFBundleVersion='1',LSMinimumSystemVersion='14.0',NSPrincipalClass='NSApplication',NSHighResolutionCapable=True)))
PY
codesign --force --sign - "$bundle/Contents/Frameworks/libJHCutCore.dylib"
codesign --force --sign - "$bundle"
