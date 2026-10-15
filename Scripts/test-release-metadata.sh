#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 -B Tests/ReleaseMetadataTests.py "${1:-Artifacts/ReleaseMetadataTests/run-$(uuidgen)}"
