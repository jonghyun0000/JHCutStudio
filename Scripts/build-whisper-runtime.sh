#!/bin/bash
set -euo pipefail
JHCUT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$JHCUT_ROOT"
export DEVELOPER_DIR="${JHCUT_DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
# Downloads source/build tooling only. NEVER downloads speech models.
JHCUT_SOURCE_URL='https://api.github.com/repos/ggml-org/whisper.cpp/tarball/v1.9.4'
JHCUT_SOURCE_SHA='261de3e2edeb7b3fa8bd3b35d000848fb023933ca220bf4d15937e31f8992ec8'
mkdir -p Build/whisper-source Resources/Whisper
if [[ ! -f Build/whisper-source/v1.9.4.tar.gz ]]; then
  curl --fail --location --proto '=https' --tlsv1.2 "$JHCUT_SOURCE_URL" -o Build/whisper-source/v1.9.4.tar.gz
fi
JHCUT_ACTUAL_SHA="$(shasum -a 256 Build/whisper-source/v1.9.4.tar.gz | cut -d ' ' -f 1)"
if [[ "$JHCUT_ACTUAL_SHA" != "$JHCUT_SOURCE_SHA" ]]; then echo 'whisper.cpp source checksum mismatch; refusing to build.' >&2; exit 1; fi
tar -xzf Build/whisper-source/v1.9.4.tar.gz -C Build/whisper-source --strip-components=1
if [[ ! -x Build/whisper-tools/cmake/data/bin/cmake ]]; then
  python3 -m pip install --target Build/whisper-tools cmake==4.1.3 --no-deps --disable-pip-version-check
fi
JHCUT_CMAKE="$JHCUT_ROOT/Build/whisper-tools/cmake/data/bin/cmake"
"$JHCUT_CMAKE" -S Build/whisper-source -B Build/whisper-runtime -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=OFF \
  -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=ON -DWHISPER_CURL=OFF
"$JHCUT_CMAKE" --build Build/whisper-runtime --target whisper-cli -j "${JHCUT_BUILD_JOBS:-6}"
cp Build/whisper-runtime/bin/whisper-cli Resources/Whisper/whisper-cli
cp Build/whisper-source/LICENSE Resources/Whisper/LICENSE-whisper.cpp.txt
Resources/Whisper/whisper-cli --help >/dev/null 2>&1
echo 'Built offline whisper.cpp runtime. Models require a separate explicit installation approval.'
