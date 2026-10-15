#!/bin/bash
set -euo pipefail
JHCUT_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$JHCUT_ROOT"
export DEVELOPER_DIR="${JHCUT_DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
# Downloads pinned source/build tooling only. NEVER downloads speech models.
JHCUT_SOURCE_URL='https://api.github.com/repos/ggml-org/whisper.cpp/tarball/v1.9.4'
JHCUT_SOURCE_SHA='261de3e2edeb7b3fa8bd3b35d000848fb023933ca220bf4d15937e31f8992ec8'
JHCUT_SOURCE_COMMIT='927cfce34f31707e17f2bff35c349632fb9e2c3a'
JHCUT_ARCHIVE="$JHCUT_ROOT/Build/whisper-source/v1.9.4.tar.gz"
JHCUT_WHISPER_OUTPUT_DIR="${JHCUT_WHISPER_OUTPUT_DIR:-$JHCUT_ROOT/Resources/Whisper}"
JHCUT_SDK_PATH="${JHCUT_SDK:-$DEVELOPER_DIR/SDKs/MacOSX26.5.sdk}"
JHCUT_JOBS="${JHCUT_BUILD_JOBS:-2}"
[[ "$JHCUT_JOBS" =~ ^[1-9][0-9]*$ ]] || { echo 'Build jobs must be a positive integer.' >&2; exit 1; }
[[ -d "$JHCUT_SDK_PATH" ]] || { echo 'Matching macOS SDK is missing; set JHCUT_SDK.' >&2; exit 1; }
# Both Command Line Tools and full Xcode honor this process-local selection.
JHCUT_C_COMPILER="$(xcrun --find clang)"
JHCUT_CXX_COMPILER="$(xcrun --find clang++)"
for notice in runtime-and-model.json LICENSE-whisper.cpp.txt LICENSE-whisper-model.txt THIRD-PARTY-NOTICES.txt; do
  [[ -f "Resources/Whisper/$notice" ]] || { echo "Missing existing provenance/notice: $notice" >&2; exit 1; }
done
mkdir -p "$JHCUT_ROOT/Build/whisper-source"
if [[ ! -f "$JHCUT_ARCHIVE" ]]; then
  JHCUT_DOWNLOAD="$(mktemp "$JHCUT_ROOT/Build/whisper-source/source-download.XXXXXX")"
  trap 'rm -f "$JHCUT_DOWNLOAD"' EXIT
  curl --fail --location --proto '=https' --tlsv1.2 "$JHCUT_SOURCE_URL" -o "$JHCUT_DOWNLOAD"
  [[ "$(shasum -a 256 "$JHCUT_DOWNLOAD" | cut -d ' ' -f 1)" == "$JHCUT_SOURCE_SHA" ]] || { echo 'Source checksum mismatch.' >&2; exit 1; }
  mv "$JHCUT_DOWNLOAD" "$JHCUT_ARCHIVE"
  trap - EXIT
fi
[[ "$(shasum -a 256 "$JHCUT_ARCHIVE" | cut -d ' ' -f 1)" == "$JHCUT_SOURCE_SHA" ]] || { echo 'Source checksum mismatch; refusing to build.' >&2; exit 1; }
if [[ -z "${JHCUT_CMAKE:-}" ]]; then
  JHCUT_CMAKE="$JHCUT_ROOT/Build/whisper-tools/cmake/data/bin/cmake"
  if [[ ! -x "$JHCUT_CMAKE" ]]; then
    python3 -m pip install --target "$JHCUT_ROOT/Build/whisper-tools" cmake==4.1.3 --no-deps --disable-pip-version-check
  fi
fi
[[ -x "$JHCUT_CMAKE" ]] || { echo 'JHCUT_CMAKE must name an executable.' >&2; exit 1; }
[[ "$("$JHCUT_CMAKE" --version | head -n 1)" == 'cmake version 4.1.3' ]] || { echo 'Pinned CMake 4.1.3 is required.' >&2; exit 1; }
JHCUT_WORK="$(mktemp -d "$JHCUT_ROOT/Build/whisper-work.XXXXXX")"
JHCUT_SOURCE="$JHCUT_WORK/Source"
JHCUT_BUILD="$JHCUT_WORK/Build"
JHCUT_STAGE="$JHCUT_WORK/Output"
mkdir "$JHCUT_SOURCE" "$JHCUT_BUILD" "$JHCUT_STAGE" "$JHCUT_WORK/Logs"
# Do not inherit an enclosing app repository's HEAD when upstream CMake probes Git.
export GIT_CEILING_DIRECTORIES="$JHCUT_WORK"
python3 - "$JHCUT_ARCHIVE" "$JHCUT_SOURCE" "$JHCUT_SOURCE_COMMIT" "$JHCUT_WORK" <<'PY'
from pathlib import Path
import sys, tarfile, hashlib, json
archive, source, commit, work = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3], Path(sys.argv[4])
files = {}
with tarfile.open(archive, 'r:gz') as tar:
    if tar.pax_headers.get('comment') != commit: raise SystemExit('Archive PAX commit mismatch')
    for item in tar.getmembers():
        parts = Path(item.name).parts
        if len(parts) < 2: continue
        relative = Path(*parts[1:])
        if relative.is_absolute() or '..' in relative.parts: raise SystemExit('Unsafe archive member')
        destination = source / relative
        if item.isdir(): destination.mkdir(parents=True, exist_ok=True)
        elif item.isreg():
            destination.parent.mkdir(parents=True, exist_ok=True)
            content = tar.extractfile(item).read()
            with destination.open('xb') as output: output.write(content)
            destination.chmod(0o755 if item.mode & 0o111 else 0o644)
            files[str(relative)] = hashlib.sha256(content).hexdigest()
        else: raise SystemExit('Unexpected non-regular archive entry')
(work / 'source-before.json').write_text(json.dumps(files, indent=2) + '\n')
PY
# CMake compiler-flag parsing requires double quotes; shell-only single quotes are not retained.
JHCUT_PREFIX_FLAGS="$(python3 - "$JHCUT_WORK" <<'PY'
import json, sys
print('-march=armv8.2-a+fp16 ' + ' '.join(json.dumps(flag + '=' + sys.argv[1] + '=/jhcut-build') for flag in ('-ffile-prefix-map', '-fmacro-prefix-map', '-fdebug-prefix-map')))
PY
)"
"$JHCUT_C_COMPILER" --version > "$JHCUT_WORK/Logs/compiler.log"
"$JHCUT_CMAKE" --version > "$JHCUT_WORK/Logs/cmake.log"
"$JHCUT_CMAKE" -G 'Unix Makefiles' -S "$JHCUT_SOURCE" -B "$JHCUT_BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER="$JHCUT_C_COMPILER" -DCMAKE_CXX_COMPILER="$JHCUT_CXX_COMPILER" \
  -DCMAKE_OSX_SYSROOT="$JHCUT_SDK_PATH" -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  -DCMAKE_C_FLAGS="$JHCUT_PREFIX_FLAGS" -DCMAKE_CXX_FLAGS="$JHCUT_PREFIX_FLAGS" \
  -DBUILD_SHARED_LIBS=OFF -DGGML_BACKEND_DL=OFF -DGGML_METAL=OFF -DGGML_NATIVE=OFF -DGGML_CPU_ARM_ARCH=armv8.2-a+fp16 -DGGML_CPU_ALL_VARIANTS=OFF \
  -DGGML_ACCELERATE=ON -DGGML_BLAS=ON -DGGML_CPU_KLEIDIAI=OFF -DGGML_LLAMAFILE=OFF \
  -DWHISPER_BUILD_IS_DEV=ON -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=ON \
  -DWHISPER_CURL=OFF -DWHISPER_COMMON_FFMPEG=OFF 2>&1 | tee "$JHCUT_WORK/Logs/configure.log"
"$JHCUT_CMAKE" --build "$JHCUT_BUILD" --target whisper-cli -j "$JHCUT_JOBS" 2>&1 | tee "$JHCUT_WORK/Logs/build.log"
"$JHCUT_BUILD/bin/whisper-cli" --help > "$JHCUT_WORK/Logs/help.log" 2>&1
/usr/bin/codesign -dvv "$JHCUT_BUILD/bin/whisper-cli" > "$JHCUT_WORK/Logs/signature.log" 2>&1
/usr/bin/codesign --verify "$JHCUT_BUILD/bin/whisper-cli" > "$JHCUT_WORK/Logs/signature-verify.log" 2>&1
cp "$JHCUT_BUILD/bin/whisper-cli" "$JHCUT_STAGE/whisper-cli"
for notice in LICENSE-whisper.cpp.txt LICENSE-whisper-model.txt THIRD-PARTY-NOTICES.txt; do cp "Resources/Whisper/$notice" "$JHCUT_STAGE/$notice"; done
cmp "$JHCUT_SOURCE/LICENSE" "$JHCUT_STAGE/LICENSE-whisper.cpp.txt"
python3 - "$JHCUT_ROOT" "$JHCUT_WORK" "$JHCUT_SOURCE_SHA" "$JHCUT_SOURCE_COMMIT" "$JHCUT_SDK_PATH" "$JHCUT_C_COMPILER" <<'PY'
from pathlib import Path
import sys, json, hashlib, re, os
root, work, archive_sha, commit, sdk, compiler = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3], sys.argv[4], Path(sys.argv[5]), Path(sys.argv[6])
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
metadata = json.loads((root / 'Resources/Whisper/runtime-and-model.json').read_text())
if (metadata['runtime']['sourceArchiveSHA256'], metadata['runtime']['commit'], metadata['runtime']['version']) != (archive_sha, commit, 'v1.9.4'): raise SystemExit('Existing runtime provenance differs from the pinned recipe')
model = json.loads(json.dumps(metadata['model']))
source_before = json.loads((work / 'source-before.json').read_text())
source_after = {name: sha(work / 'Source' / name) for name in source_before}
if source_before != source_after: raise SystemExit('Archived source bytes changed during build')
(work / 'source-after.json').write_text(json.dumps(source_after, indent=2) + '\n')
binary = work / 'Output/whisper-cli'
raw = binary.read_bytes()
for private in ('/Volumes/', '/Users/', str(work)):
    if any(private.encode(encoding) in raw for encoding in ('utf-8', 'utf-16le', 'utf-16be')): raise SystemExit('Compiled binary contains a private build path')
signature = (work / 'Logs/signature.log').read_text()
if 'Signature=adhoc' not in signature: raise SystemExit('Expected compiler/linker ad-hoc signature not found')
flags = (work / 'Build/ggml/src/CMakeFiles/ggml-cpu.dir/flags.make').read_text()
cpu_flags = sorted(set(re.findall(r'-m(?:arch|cpu)=[^\s]+', flags)))
if '-march=armv8.2-a+fp16' not in cpu_flags or any(flag.startswith('-mcpu=') for flag in cpu_flags): raise SystemExit('Unexpected CPU target flags')
metadata['runtime'].pop('nativeCPU', None)
metadata['runtime'].update(binaryBytes=len(raw), unsignedBinarySHA256=sha(binary),
    binarySignature='linker-ad-hoc' if 'linker-signed' in signature else 'ad-hoc',
    buildRecipeVersion=3, sourceVersionReported='1.9.4-dev',
    sourcePathMapping='canonical owned work root -> /jhcut-build for C/C++ file, macro and debug prefixes',
    cpuTarget={'policy': 'GGML_NATIVE=OFF; GGML_CPU_ARM_ARCH=armv8.2-a+fp16; GGML_CPU_ALL_VARIANTS=OFF', 'architecture': 'arm64', 'isa': 'armv8.2-a+fp16', 'compilerFlags': cpu_flags, 'nativeOptimization': False, 'supportScope': 'ISA target tested only on the current Mac. Other Macs and OS versions remain unverified.'},
    compiler=(work / 'Logs/compiler.log').read_text().splitlines()[0], sdk=json.loads((sdk / 'SDKSettings.json').read_text()).get('Version'), cmake='4.1.3')
if metadata['model'] != model: raise SystemExit('Model specification changed')
(work / 'Output/runtime-and-model.json').write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + '\n')
(work / 'build-receipt.json').write_text(json.dumps({'schemaVersion': 1, 'sourceArchiveSHA256': archive_sha, 'sourceCommit': commit, 'sourceFilesUnchanged': len(source_after), 'runtimeSHA256': sha(binary), 'runtimeBytes': len(raw), 'modelSpecPreserved': True, 'compilerSHA256': sha(compiler), 'cmakeVersion': '4.1.3', 'speechRecognitionValidated': False}, indent=2) + '\n')
PY
mkdir -p "$JHCUT_WHISPER_OUTPUT_DIR"
for file in whisper-cli runtime-and-model.json LICENSE-whisper.cpp.txt LICENSE-whisper-model.txt THIRD-PARTY-NOTICES.txt; do cp "$JHCUT_STAGE/$file" "$JHCUT_WHISPER_OUTPUT_DIR/$file"; done
python3 - "$JHCUT_WHISPER_OUTPUT_DIR" <<'PY'
from pathlib import Path
import sys, json, hashlib
output = Path(sys.argv[1]); metadata = json.loads((output / 'runtime-and-model.json').read_text())['runtime']; data = (output / 'whisper-cli').read_bytes()
if metadata['binaryBytes'] != len(data) or metadata['unsignedBinarySHA256'] != hashlib.sha256(data).hexdigest(): raise SystemExit('Published runtime bytes and metadata disagree')
PY
printf 'WHISPER_BUILD_WORK=%s\nWHISPER_OUTPUT=%s\n' "$JHCUT_WORK" "$JHCUT_WHISPER_OUTPUT_DIR"
echo 'Built pinned local runtime. Speech recognition is not validated by this build. Models still require separate explicit approval.'
