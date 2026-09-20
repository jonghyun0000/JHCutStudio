#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ ! -x 'Build/JH CUT Studio.app/Contents/MacOS/JHCutStudio' ]]; then bash Scripts/build.sh; fi
open 'Build/JH CUT Studio.app' --args "$@"
