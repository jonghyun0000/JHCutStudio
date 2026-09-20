#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ ! -x Build/JHCutValidate ]]; then bash Scripts/build.sh; fi
exec Build/JHCutValidate "${1:-$PWD/Artifacts/G0}"
